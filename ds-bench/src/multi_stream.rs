use std::collections::BTreeMap;
use std::error::Error as StdError;
use std::sync::Arc;
use std::sync::atomic::AtomicU64;
use std::sync::atomic::Ordering;
use std::time::Duration;
use std::time::Instant;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Result;
use clap::Args;
use futures::stream::FuturesUnordered;
use futures::stream::StreamExt;
use hdrhistogram::Histogram;
use serde::Serialize;
use tokio::sync::Mutex;

use crate::backend::ApiStyle;
use crate::backend::Backend;
use crate::backend::Producer;
use crate::common::Counts;
use crate::common::LatencySummary;
use crate::common::build_client;
use crate::common::fill_payload;
use crate::common::merge;
use crate::common::new_histogram;
use crate::common::record;
use crate::common::summarize;

#[derive(Args, Debug, Clone)]
pub struct MultiStreamArgs {
    /// Target base URL(s). Comma-separated for round-robin across nodes.
    #[arg(long)]
    pub target: String,

    /// Backend API style.
    #[arg(long, value_enum, default_value_t = ApiStyle::Ursula)]
    pub api_style: ApiStyle,

    /// Bucket name (Ursula only - ignored by Durable / S2).
    #[arg(long, default_value = "bench-multistream")]
    pub bucket: String,

    /// Basin name (S2 only).
    #[arg(long, default_value = "benchmark")]
    pub basin: String,

    /// Number of concurrent streams; one writer task per stream.
    #[arg(long, default_value_t = 1000)]
    pub streams: usize,

    /// Offered concurrency (number of connection-workers). 0 = legacy model: one
    /// in-flight append PER stream through an idempotent producer session
    /// (ordered, deduped — throughput becomes streams/latency; pods own disjoint
    /// pod-prefixed stream sets). >0 = bounded-concurrency pool model measuring
    /// RAW append throughput over a GLOBAL key domain: exactly N=connections
    /// worker tasks (each its own connection, one in-flight append) issue PLAIN
    /// appends — no producer headers, no seq, no server-side session/dedup
    /// state — to uniformly RANDOM keys in [0, --streams). Pods are fully
    /// independent: no pre-sharding, no setup phase; streams are created lazily
    /// on first touch (append → 404 → create-tolerate-exists → retry). Offered
    /// load is decoupled from stream count in both directions, per-stream
    /// arrivals are Poisson-like superpositions of independent writers, and a
    /// degraded pod lowers offered load without skewing key coverage.
    #[arg(long, default_value_t = 0)]
    pub connections: usize,

    /// Records per append request (pool model only). 1 = one record per POST. >1 =
    /// send a JSON array of N records in a single POST (the durable server flattens
    /// the array into N records under ONE appender-lock + ONE fsync), amortizing the
    /// per-request client/server overhead; throughput counts N records per
    /// successful POST. Cuts fleet vCPU per record/s — the main load-gen cost
    /// lever. Switches the body to application/json.
    #[arg(long, default_value_t = 1)]
    pub batch: usize,

    /// Wall-clock duration to drive load, in seconds.
    #[arg(long, default_value_t = 60)]
    pub duration_secs: u64,

    /// Payload size in bytes per append.
    #[arg(long, default_value_t = 256)]
    pub payload_bytes: usize,

    /// Target appends per second per stream. 0 = as fast as possible.
    #[arg(long, default_value_t = 0)]
    pub rate_per_stream: u64,

    /// Concurrent stream-creation calls during setup.
    #[arg(long, default_value_t = 256)]
    pub setup_concurrency: usize,

    /// HTTP request timeout in seconds.
    #[arg(long, default_value_t = 30)]
    pub request_timeout_secs: u64,

    /// Warm-up seconds: drive load (advancing the producer session, warming the
    /// server's caches/allocator/WAL) but DO NOT count these ops. 0 = disabled.
    #[arg(long, default_value_t = 0)]
    pub warmup_secs: u64,

    /// Settle/wait seconds: after warm-up, go idle so the create+warm-up burst
    /// quiesces before the measured window starts. 0 = disabled.
    #[arg(long, default_value_t = 0)]
    pub settle_secs: u64,
}

#[derive(Serialize)]
pub struct MultiStreamResult {
    pub scenario: &'static str,
    pub api_style: ApiStyle,
    pub target: String,
    pub bucket: String,
    pub basin: String,
    pub streams: usize,
    pub duration_secs: u64,
    pub payload_bytes: usize,
    pub rate_per_stream: u64,
    pub elapsed_secs: f64,
    pub counts: Counts,
    pub errors: Vec<ErrorCount>,
    pub aggregate_ops_per_sec: f64,
    pub per_stream_ops_per_sec_mean: f64,
    pub latency_ms: LatencySummary,
    /// Wall-clock bounds of this pod's measure window (unix ms). The fleet sum of
    /// `aggregate_ops_per_sec` only means something when every pod's window covers
    /// the same wall time — hdr-merge uses these stamps to verify the windows
    /// actually overlapped (staggered pod starts otherwise multiply-count the
    /// server's capacity: the 500k-stream 2.9M ops/s artifact).
    pub measure_start_unix_ms: u64,
    pub measure_end_unix_ms: u64,
}

/// Per-pod stream-name prefix for the LEGACY model: its per-stream producer
/// sessions require pods to own disjoint stream sets, or pods collide on
/// producer identities and a multi-pod cell's real cardinality silently shrinks
/// to streams/pods. The indexed Job sets DS_BENCH_INSTANCE = pod ordinal;
/// single-process runs default to "0". The pool model does NOT use this: its
/// key domain is global by design (any pod writes any key).
fn instance_prefix() -> String {
    let inst = std::env::var("DS_BENCH_INSTANCE").unwrap_or_default();
    let inst = if inst.is_empty() { "0".to_string() } else { inst };
    format!("i{inst}-")
}

/// Global (pod-independent) stream name for the pool model's shared key domain.
fn stream_name_global(idx: usize) -> String {
    format!("s{idx:08}")
}

/// Tiny deterministic PRNG (xorshift64*) — no `rand` dependency, seeded per
/// (pod, worker) so runs are reproducible and workers draw independent key
/// sequences over the shared domain.
struct XorShift64(u64);

impl XorShift64 {
    fn seeded(instance: u64, worker: u64) -> Self {
        // SplitMix-style avalanche of a non-zero composite seed.
        let mut z = 0x9E37_79B9_7F4A_7C15u64
            ^ (instance.wrapping_mul(0xBF58_476D_1CE4_E5B9))
            ^ (worker.wrapping_mul(0x94D0_49BB_1331_11EB));
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        XorShift64((z ^ (z >> 31)) | 1)
    }

    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }
}

/// Planned wall-clock measure window, computed at phase setup: `Instant`-based
/// phase arithmetic mapped onto the wall clock. Drift between the monotonic and
/// wall clocks over a bench run is negligible for the overlap check this feeds.
fn wall_measure_window(warmup_secs: u64, settle_secs: u64, duration_secs: u64) -> (u64, u64) {
    let now_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;
    let start = now_ms + (warmup_secs + settle_secs) * 1000;
    (start, start + duration_secs * 1000)
}

#[derive(Clone, Debug, Serialize)]
pub struct ErrorCount {
    pub error: String,
    pub count: u64,
}

pub async fn run(args: MultiStreamArgs) -> Result<MultiStreamResult> {
    let client = build_client(args.request_timeout_secs)?;
    let backend = Backend::new(
        args.api_style,
        &args.target,
        &args.bucket,
        &args.basin,
        client,
    );

    tracing::info!(
        "creating namespace and streams: api={} streams={} targets={}",
        args.api_style.as_str(),
        args.streams,
        backend.bases.len()
    );
    backend.ensure_namespace().await?;

    if args.connections > 0 {
        // Pool model: NO setup phase. Pods are fully independent — every worker
        // draws random keys over the GLOBAL --streams domain and streams are
        // created lazily on first touch (append → 404 → create → retry; creation
        // races are safe: create is create-only + tolerate-exists, and pool
        // appends carry no producer identity to collide on). The barrier below
        // is kept for exactly one reason: aligning the fleet's measure windows.
        crate::barrier::sync_to_fleet_start().await;
        return run_pool(args, backend).await;
    }

    create_streams(&backend, args.streams, args.setup_concurrency, "application/octet-stream")
        .await?;

    // Fleet start barrier (no-op unless DS_BENCH_BARRIER_DIR is set): hold here —
    // AFTER setup, BEFORE any load phase — until every pod is ready and the
    // leader's go time arrives, so all measure windows cover the same wall time.
    crate::barrier::sync_to_fleet_start().await;

    let payload = Arc::new(fill_payload(args.payload_bytes, 0xC0FFEE));
    let ok = Arc::new(AtomicU64::new(0));
    let bp = Arc::new(AtomicU64::new(0));
    let err = Arc::new(AtomicU64::new(0));
    let errors = Arc::new(Mutex::new(BTreeMap::<String, u64>::new()));
    let hist = Arc::new(Mutex::new(new_histogram()));

    // Three phases on ONE continuous producer session (seq advances throughout,
    // so no dedup collisions): warm-up (uncounted) → settle (idle) → measure (counted).
    let base = Instant::now();
    let warmup_end = base + Duration::from_secs(args.warmup_secs);
    let measure_start = warmup_end + Duration::from_secs(args.settle_secs);
    let deadline = measure_start + Duration::from_secs(args.duration_secs);
    let (measure_start_unix_ms, measure_end_unix_ms) =
        wall_measure_window(args.warmup_secs, args.settle_secs, args.duration_secs);

    let mut workers = Vec::with_capacity(args.streams);
    for idx in 0..args.streams {
        let backend = backend.clone();
        let stream = stream_name(idx);
        let payload = payload.clone();
        let ok = ok.clone();
        let bp = bp.clone();
        let err = err.clone();
        let errors = errors.clone();
        let hist = hist.clone();
        let rate = args.rate_per_stream;
        let producer_id = format!("bench-{idx}");
        workers.push(tokio::spawn(async move {
            run_writer(
                backend,
                idx,
                stream,
                payload,
                producer_id,
                rate,
                warmup_end,
                measure_start,
                deadline,
                ok,
                bp,
                err,
                errors,
                hist,
            )
            .await
        }));
    }

    for w in workers {
        let _ = w.await;
    }

    let counts = Counts {
        ok: ok.load(Ordering::Relaxed),
        backpressure: bp.load(Ordering::Relaxed),
        other_err: err.load(Ordering::Relaxed),
    };
    let errors = errors
        .lock()
        .await
        .iter()
        .map(|(error, count)| ErrorCount {
            error: error.clone(),
            count: *count,
        })
        .collect();
    let h = hist.lock().await;
    let latency = summarize(&h);
    crate::dist::emit_hdr(&h, &format!("multi-stream-{}", std::process::id()));
    let elapsed_secs = args.duration_secs as f64; // throughput over the MEASURE window only
    let aggregate = counts.ok as f64 / elapsed_secs.max(1e-9);
    let per_stream_mean = aggregate / args.streams.max(1) as f64;

    Ok(MultiStreamResult {
        scenario: "multi-stream-write",
        api_style: args.api_style,
        target: args.target,
        bucket: args.bucket,
        basin: args.basin,
        streams: args.streams,
        duration_secs: args.duration_secs,
        payload_bytes: args.payload_bytes,
        rate_per_stream: args.rate_per_stream,
        elapsed_secs,
        counts,
        errors,
        aggregate_ops_per_sec: aggregate,
        per_stream_ops_per_sec_mean: per_stream_mean,
        latency_ms: latency,
        measure_start_unix_ms,
        measure_end_unix_ms,
    })
}

/// Bounded-concurrency pool model: exactly `connections` worker tasks, each owning
/// a disjoint contiguous slice of the `streams` set, cycling appends round-robin
/// over its slice with one in-flight append at a time. Offered concurrency is
/// `connections` (NOT `streams`), so the load the server sees is controlled and the
/// client's per-pod overhead/memory stays bounded regardless of stream count.
async fn run_pool(args: MultiStreamArgs, backend: Backend) -> Result<MultiStreamResult> {
    let n = args.streams.max(1);
    // NOT capped at n: c > n pins multiple workers (distinct producer identities)
    // to the same stream — see pool_assignment.
    let c = args.connections.max(1);
    let batch = args.batch.max(1);
    // Precompute the request body once (constant across appends). batch>1 → a JSON
    // array of `batch` records (server flattens to N records under one lock/fsync).
    let (body, content_type, recs_per_post): (Arc<Vec<u8>>, &'static str, u64) = if batch > 1 {
        let rec = format!("\"{}\"", "x".repeat(args.payload_bytes));
        let mut s = String::with_capacity((rec.len() + 1) * batch + 2);
        s.push('[');
        for i in 0..batch {
            if i > 0 {
                s.push(',');
            }
            s.push_str(&rec);
        }
        s.push(']');
        (Arc::new(s.into_bytes()), "application/json", batch as u64)
    } else {
        (Arc::new(fill_payload(args.payload_bytes, 0xC0FFEE)), "application/octet-stream", 1)
    };
    let ok = Arc::new(AtomicU64::new(0));
    let bp = Arc::new(AtomicU64::new(0));
    let err = Arc::new(AtomicU64::new(0));
    let errors = Arc::new(Mutex::new(BTreeMap::<String, u64>::new()));
    let hist = Arc::new(Mutex::new(new_histogram()));

    let base = Instant::now();
    let warmup_end = base + Duration::from_secs(args.warmup_secs);
    let measure_start = warmup_end + Duration::from_secs(args.settle_secs);
    let deadline = measure_start + Duration::from_secs(args.duration_secs);
    let (measure_start_unix_ms, measure_end_unix_ms) =
        wall_measure_window(args.warmup_secs, args.settle_secs, args.duration_secs);

    let instance: u64 = std::env::var("DS_BENCH_INSTANCE")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    tracing::info!(
        "pool model: connections={c} random over global domain of {n} streams, batch={batch}"
    );

    let mut workers = Vec::with_capacity(c);
    for w in 0..c {
        let backend = backend.clone();
        let body = body.clone();
        let rng = XorShift64::seeded(instance, w as u64);
        let (ok, bp, err, errors, hist) =
            (ok.clone(), bp.clone(), err.clone(), errors.clone(), hist.clone());
        workers.push(tokio::spawn(async move {
            pool_worker(
                backend, n, rng, body, content_type, recs_per_post, warmup_end,
                measure_start, deadline, ok, bp, err, errors, hist,
            )
            .await
        }));
    }
    for wk in workers {
        let _ = wk.await;
    }

    let counts = Counts {
        ok: ok.load(Ordering::Relaxed),
        backpressure: bp.load(Ordering::Relaxed),
        other_err: err.load(Ordering::Relaxed),
    };
    let errors = errors
        .lock()
        .await
        .iter()
        .map(|(error, count)| ErrorCount { error: error.clone(), count: *count })
        .collect();
    let h = hist.lock().await;
    let latency = summarize(&h);
    crate::dist::emit_hdr(&h, &format!("multi-stream-{}", std::process::id()));
    let elapsed_secs = args.duration_secs as f64;
    let aggregate = counts.ok as f64 / elapsed_secs.max(1e-9);
    let per_stream_mean = aggregate / n as f64;

    Ok(MultiStreamResult {
        scenario: "multi-stream-pool-write",
        api_style: args.api_style,
        target: args.target,
        bucket: args.bucket,
        basin: args.basin,
        streams: n,
        duration_secs: args.duration_secs,
        payload_bytes: args.payload_bytes,
        rate_per_stream: 0,
        elapsed_secs,
        counts,
        errors,
        aggregate_ops_per_sec: aggregate,
        per_stream_ops_per_sec_mean: per_stream_mean,
        latency_ms: latency,
        measure_start_unix_ms,
        measure_end_unix_ms,
    })
}

#[allow(clippy::too_many_arguments)]
async fn pool_worker(
    backend: Backend,
    domain: usize,
    mut rng: XorShift64,
    body: Arc<Vec<u8>>,
    content_type: &'static str,
    recs_per_post: u64,
    warmup_end: Instant,
    measure_start: Instant,
    deadline: Instant,
    ok: Arc<AtomicU64>,
    bp: Arc<AtomicU64>,
    err: Arc<AtomicU64>,
    errors: Arc<Mutex<BTreeMap<String, u64>>>,
    hist: Arc<Mutex<Histogram<u64>>>,
) {
    let mut local = new_histogram();
    while Instant::now() < deadline {
        let now = Instant::now();
        if now >= warmup_end && now < measure_start {
            tokio::time::sleep(measure_start.saturating_duration_since(now)).await;
            continue;
        }
        let counting = now >= measure_start;
        // Uniform random key over the GLOBAL domain — every pod/worker can hit
        // every stream; no client↔stream binding to leave a fingerprint on the
        // per-stream arrival pattern.
        let global = (rng.next() % domain as u64) as usize;
        let stream = stream_name_global(global);
        let started = Instant::now();
        // RAW throughput: plain append, no producer session/seq/dedup — the
        // measurement is the server's append path, not its idempotency layer.
        let resp = backend
            .append_request(global, &stream, &body, None, content_type)
            .send()
            .await;
        match resp {
            Ok(r) => {
                let status = r.status();
                if status.is_success() {
                    if counting {
                        ok.fetch_add(recs_per_post, Ordering::Relaxed);
                        record(&mut local, started);
                    }
                } else if status.as_u16() == 404 {
                    // Lazy creation: first touch of this key. Create (create-only,
                    // tolerate-exists — racing pods are fine) and retry the append
                    // once. The op's recorded latency includes the create: that is
                    // the honest client-observed cost, and after warmup nearly the
                    // whole domain exists so these are rare.
                    if backend.create_stream(&stream, content_type).await.is_ok() {
                        let retry = backend
                            .append_request(global, &stream, &body, None, content_type)
                            .send()
                            .await;
                        match retry {
                            Ok(r2) if r2.status().is_success() => {
                                if counting {
                                    ok.fetch_add(recs_per_post, Ordering::Relaxed);
                                    record(&mut local, started);
                                }
                            }
                            Ok(r2) => {
                                if counting {
                                    err.fetch_add(1, Ordering::Relaxed);
                                    record_error(
                                        &errors,
                                        format!("http_status_{}_after_create", r2.status().as_u16()),
                                    )
                                    .await;
                                }
                            }
                            Err(e) => {
                                if counting {
                                    err.fetch_add(1, Ordering::Relaxed);
                                    record_error(&errors, reqwest_error_chain(&e)).await;
                                }
                            }
                        }
                    } else if counting {
                        err.fetch_add(1, Ordering::Relaxed);
                        record_error(&errors, "create_failed".to_string()).await;
                    }
                } else if status.as_u16() == 503 || status.as_u16() == 429 {
                    if counting {
                        bp.fetch_add(1, Ordering::Relaxed);
                    }
                    tokio::time::sleep(Duration::from_millis(20)).await;
                } else if counting {
                    err.fetch_add(1, Ordering::Relaxed);
                    record_error(&errors, format!("http_status_{}", status.as_u16())).await;
                }
            }
            Err(e) => {
                if counting {
                    err.fetch_add(1, Ordering::Relaxed);
                    record_error(&errors, reqwest_error_chain(&e)).await;
                }
            }
        }
    }
    let mut h = hist.lock().await;
    merge(&mut h, &local);
}

#[allow(clippy::too_many_arguments)]
async fn run_writer(
    backend: Backend,
    base_idx: usize,
    stream: String,
    payload: Arc<Vec<u8>>,
    producer_id: String,
    rate_per_stream: u64,
    warmup_end: Instant,
    measure_start: Instant,
    deadline: Instant,
    ok: Arc<AtomicU64>,
    bp: Arc<AtomicU64>,
    err: Arc<AtomicU64>,
    errors: Arc<Mutex<BTreeMap<String, u64>>>,
    hist: Arc<Mutex<Histogram<u64>>>,
) {
    let epoch: u64 = 0;
    let mut seq: u64 = 0;
    let interval = if rate_per_stream > 0 {
        Some(Duration::from_micros(1_000_000 / rate_per_stream.max(1)))
    } else {
        None
    };
    let mut next_at = Instant::now();
    let mut local = new_histogram();
    let use_producer = matches!(backend.kind, ApiStyle::Ursula | ApiStyle::Durable);
    while Instant::now() < deadline {
        let now = Instant::now();
        // SETTLE/WAIT phase: idle between warm-up and the measure window so the
        // create + warm-up burst quiesces before we start counting.
        if now >= warmup_end && now < measure_start {
            tokio::time::sleep(measure_start.saturating_duration_since(now)).await;
            continue;
        }
        // Count only in the measure window; warm-up still appends (advancing seq +
        // warming the server) but is not counted.
        let counting = now >= measure_start;
        if let Some(iv) = interval {
            let now = Instant::now();
            if now < next_at {
                tokio::time::sleep(next_at - now).await;
            }
            next_at += iv;
        }
        let started = Instant::now();
        let producer = if use_producer {
            Some(Producer {
                id: &producer_id,
                epoch,
                seq,
            })
        } else {
            None
        };
        let resp = backend
            .append_request(
                base_idx,
                &stream,
                &payload,
                producer,
                "application/octet-stream",
            )
            .send()
            .await;
        match resp {
            Ok(r) => {
                let status = r.status();
                if status.is_success() {
                    if counting {
                        ok.fetch_add(1, Ordering::Relaxed);
                        record(&mut local, started);
                    }
                    seq += 1; // advance in BOTH warm-up and measure → one continuous session
                } else if status.as_u16() == 503 || status.as_u16() == 429 {
                    if counting {
                        bp.fetch_add(1, Ordering::Relaxed);
                    }
                    tokio::time::sleep(Duration::from_millis(20)).await;
                } else if counting {
                    err.fetch_add(1, Ordering::Relaxed);
                    record_error(&errors, format!("http_status_{}", status.as_u16())).await;
                }
            }
            Err(e) => {
                if counting {
                    err.fetch_add(1, Ordering::Relaxed);
                    record_error(&errors, reqwest_error_chain(&e)).await;
                }
            }
        }
    }
    let mut h = hist.lock().await;
    merge(&mut h, &local);
}

async fn record_error(errors: &Mutex<BTreeMap<String, u64>>, error: String) {
    let mut errors = errors.lock().await;
    *errors.entry(error).or_default() += 1;
}

fn reqwest_error_chain(error: &reqwest::Error) -> String {
    let mut parts = Vec::new();
    let mut source = error.source();
    while let Some(err) = source {
        parts.push(err.to_string());
        source = err.source();
    }
    if parts.is_empty() {
        error.to_string()
    } else {
        parts.join(" | caused by: ")
    }
}

async fn create_streams(
    backend: &Backend,
    count: usize,
    concurrency: usize,
    content_type: &'static str,
) -> Result<()> {
    let mut pending: FuturesUnordered<_> = FuturesUnordered::new();
    let mut next = 0usize;
    let max = concurrency.max(1);
    let push_one = |i: usize, pending: &mut FuturesUnordered<_>| {
        let backend = backend.clone();
        let stream = stream_name(i);
        pending.push(tokio::spawn(async move {
            backend
                .create_stream(&stream, content_type)
                .await
        }));
    };
    while next < count && pending.len() < max {
        push_one(next, &mut pending);
        next += 1;
    }
    while let Some(joined) = pending.next().await {
        joined??;
        if next < count {
            push_one(next, &mut pending);
            next += 1;
        }
    }
    Ok(())
}

fn stream_name(idx: usize) -> String {
    // Pod-namespaced: pods own disjoint stream sets (see instance_prefix).
    use std::sync::OnceLock;
    static PREFIX: OnceLock<String> = OnceLock::new();
    let prefix = PREFIX.get_or_init(instance_prefix);
    format!("{prefix}s{idx:08}")
}

#[cfg(test)]
mod tests {
    use super::XorShift64;

    /// Same (pod, worker) seed → same key sequence: runs are reproducible.
    /// Different workers → different sequences.
    #[test]
    fn rng_is_deterministic_per_pod_worker() {
        let a: Vec<u64> = {
            let mut r = XorShift64::seeded(3, 7);
            (0..64).map(|_| r.next()).collect()
        };
        let b: Vec<u64> = {
            let mut r = XorShift64::seeded(3, 7);
            (0..64).map(|_| r.next()).collect()
        };
        assert_eq!(a, b, "same seed must reproduce the same sequence");
        let c: Vec<u64> = {
            let mut r = XorShift64::seeded(3, 8);
            (0..64).map(|_| r.next()).collect()
        };
        assert_ne!(a, c, "different workers must draw different sequences");
    }

    /// Uniform draws over a domain cover every key and stay roughly balanced —
    /// the property that keeps writes distributed across the whole key space.
    #[test]
    fn rng_covers_domain_roughly_uniformly() {
        let n = 1000usize;
        let draws = 100_000usize;
        let mut counts = vec![0u32; n];
        let mut r = XorShift64::seeded(1, 2);
        for _ in 0..draws {
            counts[(r.next() % n as u64) as usize] += 1;
        }
        assert!(counts.iter().all(|&x| x > 0), "every key must be touched");
        let mean = draws as f64 / n as f64; // 100
        let (min, max) = (
            *counts.iter().min().unwrap() as f64,
            *counts.iter().max().unwrap() as f64,
        );
        assert!(min > mean * 0.5 && max < mean * 1.5, "roughly uniform (min={min} max={max})");
    }
}
