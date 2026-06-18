use std::sync::Arc;
use std::sync::atomic::AtomicU64;
use std::sync::atomic::Ordering;
use std::time::Duration;
use std::time::Instant;

use anyhow::Context;
use anyhow::Result;
use bytes::BytesMut;
use clap::Args;
use futures::StreamExt;
use hdrhistogram::Histogram;
use serde::Serialize;
use tokio::sync::Barrier;
use tokio::sync::Mutex;

use crate::backend::ApiStyle;
use crate::backend::Backend;
use crate::backend::Producer;
use crate::common::Counts;
use crate::common::LatencySummary;
use crate::common::build_client;
use crate::common::merge;
use crate::common::new_histogram;
use crate::common::record;
use crate::common::summarize;
use crate::sse_util::build_payload;
use crate::sse_util::extract_send_ns_maybe_b64;
use crate::sse_util::find_event_end;
use crate::sse_util::parse_sse_data;
use crate::sse_util::unix_nanos_now;

#[derive(Args, Debug, Clone)]
pub struct MixedArgs {
    /// Target base URL(s). Comma-separated for round-robin across nodes.
    #[arg(long)]
    pub target: String,

    /// Backend API style.
    #[arg(long, value_enum, default_value_t = ApiStyle::Ursula)]
    pub api_style: ApiStyle,

    /// Bucket name (Ursula only - ignored by Durable / S2).
    #[arg(long, default_value = "bench-mixed")]
    pub bucket: String,

    /// Basin name (S2 only).
    #[arg(long, default_value = "benchmark")]
    pub basin: String,

    /// Number of shared streams.
    #[arg(long, default_value_t = 50)]
    pub streams: usize,

    /// Writer tasks per stream.
    #[arg(long, default_value_t = 1)]
    pub writers_per_stream: usize,

    /// Number of catch-up reader tasks.
    #[arg(long, default_value_t = 50)]
    pub readers: usize,

    /// Number of SSE subscriber tasks.
    #[arg(long, default_value_t = 50)]
    pub subscribers: usize,

    /// Target appends per second per writer task.
    #[arg(long, default_value_t = 50)]
    pub writer_rate: u64,

    /// Wall-clock duration to drive load, in seconds.
    #[arg(long, default_value_t = 30)]
    pub duration_secs: u64,

    /// Payload size in bytes per append.
    #[arg(long, default_value_t = 256)]
    pub payload_bytes: usize,

    /// Concurrent stream-creation calls during setup.
    #[arg(long, default_value_t = 32)]
    pub setup_concurrency: usize,

    /// HTTP request timeout in seconds.
    #[arg(long, default_value_t = 30)]
    pub request_timeout_secs: u64,
}

#[derive(Serialize)]
pub struct MixedResult {
    pub scenario: &'static str,
    pub api_style: ApiStyle,
    pub target: String,
    pub bucket: String,
    pub streams: usize,
    pub writers_per_stream: usize,
    pub readers: usize,
    pub subscribers: usize,
    pub writer_rate: u64,
    pub duration_secs: u64,
    pub payload_bytes: usize,
    pub elapsed_secs: f64,
    pub write_counts: Counts,
    pub events_received: u64,
    pub read_counts: Counts,
    pub aggregate_ops_per_sec: f64,
    pub write_latency_ms: LatencySummary,
    pub fan_out_latency_ms: LatencySummary,
    pub read_latency_ms: LatencySummary,
}

pub async fn run(args: MixedArgs) -> Result<MixedResult> {
    if args.api_style == ApiStyle::S2 {
        anyhow::bail!("mixed workload is not supported for S2 Lite (no comparable catch-up read)");
    }

    let client = build_client(args.request_timeout_secs)?;
    let backend = Backend::new(
        args.api_style,
        &args.target,
        &args.bucket,
        &args.basin,
        client,
    );

    tracing::info!(
        "mixed: creating namespace and {} streams (api={})",
        args.streams,
        args.api_style.as_str()
    );
    backend.ensure_namespace().await?;
    create_streams(&backend, args.streams, args.setup_concurrency).await?;

    // Pre-load each stream with a small backfill so catch-up readers have data.
    let backfill_events = 200usize;
    preload_streams(
        &backend,
        args.streams,
        backfill_events,
        args.payload_bytes,
        args.setup_concurrency,
    )
    .await?;

    let write_hist = Arc::new(Mutex::new(new_histogram()));
    let fanout_hist = Arc::new(Mutex::new(new_histogram()));
    let read_hist = Arc::new(Mutex::new(new_histogram()));

    let write_ok = Arc::new(AtomicU64::new(0));
    let write_bp = Arc::new(AtomicU64::new(0));
    let write_err = Arc::new(AtomicU64::new(0));

    let read_ok = Arc::new(AtomicU64::new(0));
    let read_bp = Arc::new(AtomicU64::new(0));
    let read_err = Arc::new(AtomicU64::new(0));

    let events_received = Arc::new(AtomicU64::new(0));

    let start = Instant::now();

    let payload_bytes = args.payload_bytes.max(49); // min for timestamp embedding

    // Barrier: all subscribers connect first, then they and the writers all
    // release together so writers never send before any subscriber is live.
    // Participants = subscribers + total_writers (each writer waits once).
    let total_writers = args.writers_per_stream * args.streams;
    let barrier_n = args.subscribers + total_writers;
    let ready_barrier = Arc::new(Barrier::new(barrier_n.max(1)));

    // deadline is set by the first writer to cross the barrier, so subscribers
    // get the same wall-clock window.
    let deadline_cell = Arc::new(tokio::sync::OnceCell::<Instant>::new());
    let duration_secs = args.duration_secs;

    let mut handles = Vec::with_capacity(total_writers + args.readers + args.subscribers);

    // --- SSE subscriber tasks (spawned first so they connect before writers) ---
    let idle = Duration::from_secs(args.request_timeout_secs.max(10));
    for sub_idx in 0..args.subscribers {
        let backend = backend.clone();
        let stream_idx = sub_idx % args.streams;
        let stream = stream_name(stream_idx);
        let recv = events_received.clone();
        let fanout_hist = fanout_hist.clone();
        let barrier = ready_barrier.clone();
        let deadline_cell = deadline_cell.clone();
        handles.push(tokio::spawn(async move {
            if let Err(e) = run_subscriber_task(
                &backend,
                sub_idx,
                &stream,
                barrier,
                deadline_cell,
                recv,
                fanout_hist,
                idle,
            )
            .await
            {
                tracing::warn!("subscriber failed: idx={sub_idx} error={e:#}");
            }
        }));
    }

    // --- Writer tasks (each waits at the barrier before its first append) ---
    for writer_idx in 0..total_writers {
        let backend = backend.clone();
        let stream_idx = writer_idx % args.streams;
        let stream = stream_name(stream_idx);
        let write_ok = write_ok.clone();
        let write_bp = write_bp.clone();
        let write_err = write_err.clone();
        let write_hist = write_hist.clone();
        let rate = args.writer_rate;
        let producer_id = format!("mixed-w{writer_idx}");
        let barrier = ready_barrier.clone();
        let deadline_cell = deadline_cell.clone();
        handles.push(tokio::spawn(async move {
            run_writer_task(
                backend,
                stream_idx,
                stream,
                producer_id,
                payload_bytes,
                rate,
                duration_secs,
                barrier,
                deadline_cell,
                write_ok,
                write_bp,
                write_err,
                write_hist,
            )
            .await
        }));
    }

    // --- Catch-up reader tasks (no barrier needed — they replay from offset -1) ---
    // Readers share the same deadline_cell as writers/subscribers so all three
    // groups run over an identical wall-clock window.
    for reader_idx in 0..args.readers {
        let backend = backend.clone();
        let stream_idx = reader_idx % args.streams;
        let stream = stream_name(stream_idx);
        let read_ok = read_ok.clone();
        let read_bp = read_bp.clone();
        let read_err = read_err.clone();
        let read_hist = read_hist.clone();
        let deadline_cell = deadline_cell.clone();
        handles.push(tokio::spawn(async move {
            run_reader_task(
                backend,
                reader_idx,
                stream,
                deadline_cell,
                idle,
                read_ok,
                read_bp,
                read_err,
                read_hist,
            )
            .await
        }));
    }

    for h in handles {
        let _ = h.await;
    }

    let elapsed = start.elapsed();
    let elapsed_secs = elapsed.as_secs_f64();

    let write_counts = Counts {
        ok: write_ok.load(Ordering::Relaxed),
        backpressure: write_bp.load(Ordering::Relaxed),
        other_err: write_err.load(Ordering::Relaxed),
    };
    let read_counts = Counts {
        ok: read_ok.load(Ordering::Relaxed),
        backpressure: read_bp.load(Ordering::Relaxed),
        other_err: read_err.load(Ordering::Relaxed),
    };

    let wh = write_hist.lock().await;
    let fh = fanout_hist.lock().await;
    let rh = read_hist.lock().await;

    let write_latency_ms = summarize(&wh);
    let fan_out_latency_ms = summarize(&fh);
    let read_latency_ms = summarize(&rh);

    let pid = std::process::id();
    crate::dist::emit_hdr(&wh, &format!("mixed-write-{pid}"));
    crate::dist::emit_hdr(&fh, &format!("mixed-fanout-{pid}"));
    crate::dist::emit_hdr(&rh, &format!("mixed-read-{pid}"));

    let aggregate_ops_per_sec = write_counts.ok as f64 / elapsed_secs.max(1e-9);

    Ok(MixedResult {
        scenario: "mixed",
        api_style: args.api_style,
        target: args.target,
        bucket: args.bucket,
        streams: args.streams,
        writers_per_stream: args.writers_per_stream,
        readers: args.readers,
        subscribers: args.subscribers,
        writer_rate: args.writer_rate,
        duration_secs: args.duration_secs,
        payload_bytes: args.payload_bytes,
        elapsed_secs,
        write_counts,
        events_received: events_received.load(Ordering::Relaxed),
        read_counts,
        aggregate_ops_per_sec,
        write_latency_ms,
        fan_out_latency_ms,
        read_latency_ms,
    })
}

// ── Writer task ──────────────────────────────────────────────────────────────

#[allow(clippy::too_many_arguments)]
async fn run_writer_task(
    backend: Backend,
    base_idx: usize,
    stream: String,
    producer_id: String,
    payload_bytes: usize,
    rate: u64,
    duration_secs: u64,
    barrier: Arc<Barrier>,
    deadline_cell: Arc<tokio::sync::OnceCell<Instant>>,
    ok: Arc<AtomicU64>,
    bp: Arc<AtomicU64>,
    err: Arc<AtomicU64>,
    hist: Arc<Mutex<Histogram<u64>>>,
) {
    // Wait until all subscribers have established their SSE connections.
    barrier.wait().await;
    // First writer to cross sets the shared deadline.
    let deadline = *deadline_cell.get_or_init(|| async {
        Instant::now() + Duration::from_secs(duration_secs)
    }).await;

    let epoch: u64 = 0;
    let mut seq: u64 = 0;
    let interval = if rate > 0 {
        Some(Duration::from_micros(1_000_000 / rate.max(1)))
    } else {
        None
    };
    let mut next_at = Instant::now();
    let mut local = new_histogram();
    let use_producer = matches!(backend.kind, ApiStyle::Ursula | ApiStyle::Durable);

    while Instant::now() < deadline {
        if let Some(iv) = interval {
            let now = Instant::now();
            if now < next_at {
                tokio::time::sleep(next_at - now).await;
            }
            next_at += iv;
        }
        let payload = build_payload(seq, payload_bytes);
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
                    ok.fetch_add(1, Ordering::Relaxed);
                    record(&mut local, started);
                    seq += 1;
                } else if status.as_u16() == 503 || status.as_u16() == 429 {
                    bp.fetch_add(1, Ordering::Relaxed);
                    tokio::time::sleep(Duration::from_millis(20)).await;
                } else {
                    err.fetch_add(1, Ordering::Relaxed);
                }
            }
            Err(_) => {
                err.fetch_add(1, Ordering::Relaxed);
            }
        }
    }
    let mut h = hist.lock().await;
    merge(&mut h, &local);
}

// ── SSE subscriber task ──────────────────────────────────────────────────────

#[allow(clippy::too_many_arguments)]
async fn run_subscriber_task(
    backend: &Backend,
    idx: usize,
    stream: &str,
    barrier: Arc<Barrier>,
    deadline_cell: Arc<tokio::sync::OnceCell<Instant>>,
    recv: Arc<AtomicU64>,
    hist: Arc<Mutex<Histogram<u64>>>,
    idle: Duration,
) -> Result<()> {
    let (url, headers) = backend.sse_url_for(idx, stream);

    // Attempt the SSE connect — capture the outcome but do NOT return yet.
    // The barrier MUST be crossed exactly once on BOTH success and failure paths
    // so that a failed subscriber does not under-count the barrier and leave
    // all writers (and surviving subscribers) waiting forever.
    let connect_result = backend
        .client
        .get(&url)
        .headers(headers)
        .send()
        .await
        .with_context(|| format!("GET {url}"))
        .and_then(|resp| {
            if resp.status().is_success() {
                Ok(resp)
            } else {
                anyhow::bail!("SSE open: {} {}", resp.status(), url)
            }
        });

    // SSE connection attempted — cross the barrier regardless of outcome so
    // writers are never left hanging.  Successful subscribers are listening
    // before the barrier releases; failed subscribers simply won't record events.
    barrier.wait().await;

    // Now unwrap the connect result; on failure we can return cleanly.
    let resp = connect_result?;

    let mut local = new_histogram();
    let result: Result<()> = async {
        let mut stream_body = resp.bytes_stream();
        let mut buf = BytesMut::with_capacity(8192);
        let mut last_event_at = Instant::now();
        loop {
            let dl = deadline_cell.get().copied();
            if let Some(end) = dl
                && Instant::now() >= end + Duration::from_secs(2)
            {
                break;
            }
            let to = match dl {
                Some(end) => end.saturating_duration_since(Instant::now()) + Duration::from_secs(2),
                None => idle,
            }
            .min(idle);
            let next = tokio::time::timeout(to, stream_body.next()).await;
            let chunk = match next {
                Ok(Some(Ok(c))) => c,
                Ok(Some(Err(_))) | Ok(None) => break,
                Err(_) => {
                    if last_event_at.elapsed() > idle {
                        break;
                    }
                    continue;
                }
            };
            buf.extend_from_slice(&chunk);
            while let Some(idx) = find_event_end(&buf) {
                let raw = buf.split_to(idx + 2).freeze();
                let maybe_ns = if let Some(p) = parse_sse_data(&raw) {
                    extract_send_ns_maybe_b64(&p)
                } else {
                    None
                };
                if let Some(sent_ns) = maybe_ns {
                    let now_ns = unix_nanos_now();
                    let lat_ns = now_ns.saturating_sub(sent_ns);
                    let us_u128 = lat_ns / 1000;
                    let us = us_u128.min(u128::from(local.high())) as u64;
                    if us > 0 {
                        let _ = local.record(us);
                    }
                    recv.fetch_add(1, Ordering::Relaxed);
                    last_event_at = Instant::now();
                } else if parse_sse_data(&raw).is_some() {
                    // We received an SSE event but could not extract a timestamp.
                    // Still count it so events_received is not zero.
                    recv.fetch_add(1, Ordering::Relaxed);
                    last_event_at = Instant::now();
                }
            }
        }
        Ok(())
    }
    .await;

    let mut h = hist.lock().await;
    merge(&mut h, &local);
    result
}

// ── Catch-up reader task ─────────────────────────────────────────────────────

#[allow(clippy::too_many_arguments)]
async fn run_reader_task(
    backend: Backend,
    base_idx: usize,
    stream: String,
    deadline_cell: Arc<tokio::sync::OnceCell<Instant>>,
    idle: Duration,
    ok: Arc<AtomicU64>,
    bp: Arc<AtomicU64>,
    err: Arc<AtomicU64>,
    hist: Arc<Mutex<Histogram<u64>>>,
) {
    // Mirror run_subscriber_task: while the deadline hasn't been set (writers
    // haven't crossed the barrier yet) keep running but honour an idle
    // fallback so we never spin forever.  Once the shared deadline is set we
    // stop at exactly the same wall-clock instant as writers/subscribers.
    let started_at = Instant::now();
    let mut local = new_histogram();
    loop {
        let dl = deadline_cell.get().copied();
        if let Some(end) = dl {
            if Instant::now() >= end {
                break;
            }
        } else {
            // Writers haven't started yet; bail out if we've been running
            // longer than the idle fallback (prevents spinning forever if
            // something goes wrong before the barrier fires).
            if started_at.elapsed() > idle {
                break;
            }
        }
        let t = Instant::now();
        match crate::catch_up::catch_up_read_all(&backend, base_idx, &stream).await {
            Ok(_bytes) => {
                ok.fetch_add(1, Ordering::Relaxed);
                record(&mut local, t);
            }
            Err(e) => {
                let msg = e.to_string();
                if msg.contains("503") || msg.contains("429") {
                    bp.fetch_add(1, Ordering::Relaxed);
                    tokio::time::sleep(Duration::from_millis(50)).await;
                } else {
                    err.fetch_add(1, Ordering::Relaxed);
                }
            }
        }
    }
    let mut h = hist.lock().await;
    merge(&mut h, &local);
}

// ── Setup helpers ────────────────────────────────────────────────────────────

async fn create_streams(backend: &Backend, count: usize, concurrency: usize) -> Result<()> {
    use futures::stream::FuturesUnordered;
    let mut pending: FuturesUnordered<_> = FuturesUnordered::new();
    let mut next = 0usize;
    let max = concurrency.max(1);
    let push_one = |i: usize, pending: &mut FuturesUnordered<_>| {
        let backend = backend.clone();
        let stream = stream_name(i);
        pending.push(tokio::spawn(async move {
            backend
                .create_stream(&stream, "application/octet-stream")
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

async fn preload_streams(
    backend: &Backend,
    streams: usize,
    events_per_stream: usize,
    payload_bytes: usize,
    concurrency: usize,
) -> Result<()> {
    use futures::stream::FuturesUnordered;
    let payload_bytes = payload_bytes.max(49);
    let sem = Arc::new(tokio::sync::Semaphore::new(concurrency.max(1)));
    let mut pending: FuturesUnordered<_> = FuturesUnordered::new();
    let total = streams * events_per_stream;
    let mut launched = 0usize;
    let max = concurrency.max(1);

    while launched < total || !pending.is_empty() {
        while launched < total && pending.len() < max {
            let permit = sem.clone().acquire_owned().await.unwrap();
            let backend = backend.clone();
            let stream = stream_name(launched % streams);
            let payload = build_payload(launched as u64, payload_bytes);
            pending.push(tokio::spawn(async move {
                let _permit = permit;
                backend
                    .append_request(0, &stream, &payload, None, "application/octet-stream")
                    .send()
                    .await
                    .ok();
            }));
            launched += 1;
        }
        if let Some(joined) = pending.next().await {
            joined?;
        }
    }
    Ok(())
}

fn stream_name(idx: usize) -> String {
    format!("s{:06}", idx)
}

// Payload / SSE helpers now live in `crate::sse_util` (shared with no one else —
// fanout.rs is a forked file kept verbatim and keeps its own private copies).
// Imported at the top of this file.
