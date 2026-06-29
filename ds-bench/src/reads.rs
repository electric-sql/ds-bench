use std::sync::Arc;
use std::sync::atomic::AtomicU64;
use std::sync::atomic::Ordering;
use std::time::Duration;
use std::time::Instant;

use anyhow::Result;
use clap::Args;
use hdrhistogram::Histogram;
use serde::Serialize;
use tokio::sync::Mutex;

use crate::backend::ApiStyle;
use crate::backend::Backend;
use crate::common::Counts;
use crate::common::LatencySummary;
use crate::common::build_client;
use crate::common::fill_payload;
use crate::common::merge;
use crate::common::new_histogram;
use crate::common::record;
use crate::common::summarize;

#[derive(Args, Debug, Clone)]
pub struct ReadsArgs {
    /// Target base URL(s). Comma-separated for round-robin across nodes.
    #[arg(long)]
    pub target: String,

    /// Backend API style.
    #[arg(long, value_enum, default_value_t = ApiStyle::Ursula)]
    pub api_style: ApiStyle,

    /// Bucket name (Ursula only — ignored by Durable).
    #[arg(long, default_value = "bench-reads")]
    pub bucket: String,

    /// Stream name to read from. Must be pre-seeded or seeded via --seed-bytes.
    #[arg(long, default_value = "bench-reads-stream")]
    pub stream: String,

    /// Number of streams to seed and read across. Readers are pinned to
    /// stream `reader_idx % streams` (the cardinality axis). Stream names are
    /// `{stream}-{i}` for i in 0..streams.
    #[arg(long, default_value_t = 1)]
    pub streams: usize,

    /// Payload size per record in bytes (used both for seeding and as the unit
    /// of per-read latency measurement).
    #[arg(long, default_value_t = 4096)]
    pub read_size_bytes: usize,

    /// Number of concurrent reader connections.
    #[arg(long, default_value_t = 8)]
    pub connections: usize,

    /// How long to run the sustained read loop, in seconds.
    #[arg(long, default_value_t = 60)]
    pub duration_secs: u64,

    /// Total bytes to pre-seed the stream with. Each record is `--read-size-bytes`
    /// bytes. Seeding is idempotent: if the stream already holds at least this
    /// many bytes, seeding is skipped.
    #[arg(long, default_value_t = 16_777_216)] // 16 MiB default
    pub seed_bytes: u64,

    /// HTTP request timeout in seconds.
    #[arg(long, default_value_t = 30)]
    pub request_timeout_secs: u64,
}

#[derive(Serialize)]
pub struct ReadsResult {
    pub scenario: &'static str,
    pub api_style: ApiStyle,
    pub target: String,
    pub stream: String,
    pub streams: usize,
    pub read_size_bytes: usize,
    pub connections: usize,
    pub duration_secs: u64,
    pub seed_bytes: u64,
    pub elapsed_secs: f64,
    pub counts: Counts,
    pub bytes_read_total: u64,
    pub aggregate_ops_per_sec: f64,
    pub bytes_per_sec: f64,
    pub p50_ms: f64,
    pub p90_ms: f64,
    pub p99_ms: f64,
    pub p999_ms: f64,
    pub latency_ms: LatencySummary,
}

// ---------------------------------------------------------------------------
// URL helpers (mirrors catch_up.rs)
// ---------------------------------------------------------------------------

fn read_url(b: &Backend, base_idx: usize, stream: &str, offset: &str) -> String {
    let base = b.base_for(base_idx);
    match b.kind {
        ApiStyle::Durable => format!("{base}/v1/stream/{stream}?offset={offset}"),
        ApiStyle::Ursula => format!("{base}/{}/{stream}?offset={offset}", b.bucket),
        ApiStyle::S2 => unreachable!("S2 is excluded from reads workload"),
    }
}

fn read_start(_b: &Backend) -> &'static str {
    // Both Durable and Ursula accept -1 = stream start.
    "-1"
}

/// Pin a reader to a stream: reader `idx` reads `streams[idx % streams.len()]`.
fn stream_for(streams: &[String], idx: usize) -> &str {
    &streams[idx % streams.len()]
}

// ---------------------------------------------------------------------------
// One catch-up pass: reads from `offset` until up-to-date, returns (bytes, next_start_offset).
// On up-to-date it returns offset="-1" so the next pass restarts from the beginning,
// giving us the "hot resident read" loop.
// ---------------------------------------------------------------------------
async fn catch_up_once(
    b: &Backend,
    base_idx: usize,
    stream: &str,
    start_offset: &str,
) -> anyhow::Result<(u64, String)> {
    use anyhow::Context;
    let mut offset = start_offset.to_string();
    let mut total: u64 = 0;
    let mut guard: u32 = 0;
    loop {
        let url = read_url(b, base_idx, stream, &offset);
        let resp = b.client.get(&url).send().await.context("reads GET")?;
        let status = resp.status();
        if !status.is_success() {
            anyhow::bail!("reads GET status {status}");
        }
        let up = resp
            .headers()
            .get("stream-up-to-date")
            .and_then(|v| v.to_str().ok())
            .map(|v| v.eq_ignore_ascii_case("true"))
            .unwrap_or(false);
        let next = resp
            .headers()
            .get("stream-next-offset")
            .and_then(|v| v.to_str().ok())
            .map(|s| s.to_string());
        let body = resp.bytes().await.context("reads body")?;
        total += body.len() as u64;
        guard += 1;
        match next {
            Some(n) if !up && n != offset && guard < 100_000 => offset = n,
            // Up-to-date or stalled: wrap back to start for the hot-read loop.
            _ => return Ok((total, "-1".to_string())),
        }
    }
}

// ---------------------------------------------------------------------------
// Seeding
// ---------------------------------------------------------------------------

/// Ensure the stream has at least `seed_bytes` bytes of resident data.
/// Strategy: HEAD-probe the stream; if stream-next-offset header is present
/// and > seed_bytes we skip. Otherwise append records until we reach seed_bytes.
/// Errors during the probe are treated as "stream needs seeding" so we proceed.
async fn ensure_seeded(b: &Backend, stream: &str, seed_bytes: u64, record_bytes: usize) -> Result<()> {
    if seed_bytes == 0 {
        return Ok(());
    }

    // Probe current stream size via a GET from start, reading only the first
    // response's stream-next-offset header. This is the lightest way to gauge
    // whether the stream already has data without fetching all bytes again.
    let current_bytes = probe_stream_size(b, stream).await.unwrap_or(0);
    if current_bytes >= seed_bytes {
        tracing::info!(
            current_bytes,
            seed_bytes,
            "stream already seeded — skipping"
        );
        return Ok(());
    }

    let need_bytes = seed_bytes.saturating_sub(current_bytes);
    let record_count = (need_bytes as usize).div_ceil(record_bytes.max(1));
    tracing::info!(
        current_bytes,
        seed_bytes,
        record_count,
        record_bytes,
        "seeding stream"
    );

    let payload = Arc::new(fill_payload(record_bytes, 0xC0DE));
    let semaphore = Arc::new(tokio::sync::Semaphore::new(32));
    let mut joins = Vec::with_capacity(record_count);

    for _ in 0..record_count {
        let permit = semaphore.clone().acquire_owned().await.unwrap();
        let b = b.clone();
        let stream = stream.to_string();
        let payload = payload.clone();
        joins.push(tokio::spawn(async move {
            let _permit = permit;
            b.append_request(0, &stream, &payload, None, "application/octet-stream")
                .send()
                .await
                .map(|r| r.status().is_success())
                .unwrap_or(false)
        }));
    }

    let mut failed = 0u64;
    for j in joins {
        if !j.await.unwrap_or(false) {
            failed += 1;
        }
    }
    if failed > 0 {
        tracing::warn!(failed, record_count, "some seed appends failed");
    }
    Ok(())
}

/// Probe stream byte size by issuing one GET from the start and reading the
/// `stream-next-offset` header (which is the byte offset of the next record,
/// i.e. total bytes written).  Returns 0 if the header is absent.
async fn probe_stream_size(b: &Backend, stream: &str) -> anyhow::Result<u64> {
    let url = read_url(b, 0, stream, "-1");
    let resp = b.client.get(&url).send().await?;
    if !resp.status().is_success() {
        return Ok(0);
    }
    // Consume body to avoid leaking the connection.
    let next_offset = resp
        .headers()
        .get("stream-next-offset")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(0);
    Ok(next_offset)
}

// ---------------------------------------------------------------------------
// Sustained reader task
// ---------------------------------------------------------------------------

async fn run_reader(
    backend: Backend,
    base_idx: usize,
    stream: String,
    deadline: Instant,
    ok: Arc<AtomicU64>,
    bp: Arc<AtomicU64>,
    err: Arc<AtomicU64>,
    bytes_total: Arc<AtomicU64>,
    hist: Arc<Mutex<Histogram<u64>>>,
) {
    let mut offset = "-1".to_string();
    let mut local = new_histogram();

    while Instant::now() < deadline {
        let started = Instant::now();
        match catch_up_once(&backend, base_idx, &stream, &offset).await {
            Ok((bytes, next_offset)) => {
                ok.fetch_add(1, Ordering::Relaxed);
                bytes_total.fetch_add(bytes, Ordering::Relaxed);
                record(&mut local, started);
                offset = next_offset;
            }
            Err(e) => {
                let msg = e.to_string();
                if msg.contains("503") || msg.contains("429") {
                    bp.fetch_add(1, Ordering::Relaxed);
                    tokio::time::sleep(Duration::from_millis(20)).await;
                } else {
                    err.fetch_add(1, Ordering::Relaxed);
                }
                // Reset to start on error.
                offset = "-1".to_string();
            }
        }
    }

    let mut h = hist.lock().await;
    merge(&mut h, &local);
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub async fn run(args: ReadsArgs) -> Result<ReadsResult> {
    if args.api_style == ApiStyle::S2 {
        anyhow::bail!(
            "reads workload is not supported for S2: its paginated JSON read \
             is not comparable to the Durable Streams sendfile read path"
        );
    }

    let client = build_client(args.request_timeout_secs)?;
    let backend = Backend::new(
        args.api_style,
        &args.target,
        &args.bucket,
        "",
        client,
    );

    let n_streams = args.streams.max(1);
    let streams: Vec<String> = (0..n_streams)
        .map(|i| format!("{}-{}", args.stream, i))
        .collect();

    // Ensure namespace + every stream exists, then seed each (idempotent).
    backend.ensure_namespace().await?;
    for s in &streams {
        backend
            .create_stream(s, "application/octet-stream")
            .await?;
        ensure_seeded(&backend, s, args.seed_bytes, args.read_size_bytes).await?;
    }

    let ok = Arc::new(AtomicU64::new(0));
    let bp = Arc::new(AtomicU64::new(0));
    let err = Arc::new(AtomicU64::new(0));
    let bytes_total = Arc::new(AtomicU64::new(0));
    let hist = Arc::new(Mutex::new(new_histogram()));

    let deadline = Instant::now() + Duration::from_secs(args.duration_secs);
    let start = Instant::now();

    let mut workers = Vec::with_capacity(args.connections);
    for idx in 0..args.connections {
        let backend = backend.clone();
        let stream = stream_for(&streams, idx).to_string();
        let ok = ok.clone();
        let bp = bp.clone();
        let err = err.clone();
        let bytes_total = bytes_total.clone();
        let hist = hist.clone();
        workers.push(tokio::spawn(async move {
            run_reader(backend, idx, stream, deadline, ok, bp, err, bytes_total, hist).await
        }));
    }

    for w in workers {
        let _ = w.await;
    }

    let elapsed = start.elapsed();
    let elapsed_secs = elapsed.as_secs_f64();
    let bytes_read_total = bytes_total.load(Ordering::Relaxed);
    let ok_count = ok.load(Ordering::Relaxed);
    let aggregate_ops_per_sec = ok_count as f64 / elapsed_secs.max(1e-9);
    let bytes_per_sec = bytes_read_total as f64 / elapsed_secs.max(1e-9);

    let h = hist.lock().await;
    let latency = summarize(&h);
    crate::dist::emit_hdr(&h, &format!("reads-{}", std::process::id()));

    let result = ReadsResult {
        scenario: "reads",
        api_style: args.api_style,
        target: args.target,
        stream: args.stream,
        streams: n_streams,
        read_size_bytes: args.read_size_bytes,
        connections: args.connections,
        duration_secs: args.duration_secs,
        seed_bytes: args.seed_bytes,
        elapsed_secs,
        counts: Counts {
            ok: ok_count,
            backpressure: bp.load(Ordering::Relaxed),
            other_err: err.load(Ordering::Relaxed),
        },
        bytes_read_total,
        aggregate_ops_per_sec,
        bytes_per_sec,
        p50_ms: latency.p50_ms,
        p90_ms: latency.p90_ms,
        p99_ms: latency.p99_ms,
        p999_ms: latency.p999_ms,
        latency_ms: latency,
    };

    let json = serde_json::to_string_pretty(&result)?;
    eprintln!("{json}");

    Ok(result)
}

// Keep `read_start` from being flagged as dead code; it is intentionally
// available for future callers or tests.
#[allow(dead_code)]
fn _read_start_alias(b: &Backend) -> &'static str {
    read_start(b)
}

#[cfg(test)]
mod tests {
    use super::stream_for;

    #[test]
    fn pins_reader_to_stream_modulo_n() {
        let streams = vec!["s-0".to_string(), "s-1".to_string(), "s-2".to_string()];
        assert_eq!(stream_for(&streams, 0), "s-0");
        assert_eq!(stream_for(&streams, 2), "s-2");
        assert_eq!(stream_for(&streams, 3), "s-0"); // wraps
        assert_eq!(stream_for(&streams, 7), "s-1");
    }

    #[test]
    fn single_stream_pins_all_readers_to_it() {
        let streams = vec!["only-0".to_string()];
        assert_eq!(stream_for(&streams, 0), "only-0");
        assert_eq!(stream_for(&streams, 99), "only-0");
    }
}
