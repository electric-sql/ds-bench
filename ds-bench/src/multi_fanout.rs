//! Multi-stream fan-out workload: M streams × S subscribers each, concurrent.
//!
//! Each stream gets 1 writer pacing at `--writer-rate` events/s and S SSE
//! subscribers.  All subscribers connect before any writer sends its first
//! event (barrier-safe, same deadlock-free pattern as `mixed.rs`).
//! Delivery latency (`now − send_ns`) is recorded into a shared HDR histogram
//! using the same measurement as `fanout.rs`/`mixed.rs`.

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
use crate::common::LatencySummary;
use crate::common::build_client;
use crate::common::merge;
use crate::common::new_histogram;
use crate::common::summarize;
use crate::sse_util::build_payload;
use crate::sse_util::extract_send_ns_maybe_b64;
use crate::sse_util::find_event_end;
use crate::sse_util::parse_sse_data;
use crate::sse_util::unix_nanos_now;

#[derive(Args, Debug, Clone)]
pub struct MultiFanoutArgs {
    /// Target base URL.
    #[arg(long)]
    pub target: String,

    /// Backend API style.
    #[arg(long, value_enum, default_value_t = ApiStyle::Ursula)]
    pub api_style: ApiStyle,

    /// Bucket name (Ursula only).
    #[arg(long, default_value = "bench-multi-fanout")]
    pub bucket: String,

    /// Basin name (S2 only).
    #[arg(long, default_value = "benchmark")]
    pub basin: String,

    /// Number of independent streams.
    #[arg(long, default_value_t = 10)]
    pub streams: usize,

    /// SSE subscribers per stream.
    #[arg(long, default_value_t = 10)]
    pub subscribers_per_stream: usize,

    /// Writer events per second per stream.
    #[arg(long, default_value_t = 50)]
    pub writer_rate: u64,

    /// Wall-clock duration to drive load, in seconds.
    #[arg(long, default_value_t = 30)]
    pub duration_secs: u64,

    /// Payload size in bytes per append (min 49).
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
pub struct MultiFanoutResult {
    pub scenario: &'static str,
    pub api_style: ApiStyle,
    pub target: String,
    pub streams: usize,
    pub subscribers_per_stream: usize,
    pub writer_rate: u64,
    pub duration_secs: u64,
    pub payload_bytes: usize,
    pub elapsed_secs: f64,
    pub events_received: u64,
    pub aggregate_events_per_sec: f64,
    pub fan_out_latency_ms: LatencySummary,
}

pub async fn run(args: MultiFanoutArgs) -> Result<MultiFanoutResult> {
    let payload_bytes = args.payload_bytes.max(49);
    let client = build_client(args.request_timeout_secs)?;
    let backend = Backend::new(
        args.api_style,
        &args.target,
        &args.bucket,
        &args.basin,
        client,
    );

    tracing::info!(
        "multi-fanout: creating namespace and {} streams (api={})",
        args.streams,
        args.api_style.as_str(),
    );
    backend.ensure_namespace().await?;
    create_streams(&backend, args.streams, args.setup_concurrency).await?;

    let total_subscribers = args.streams * args.subscribers_per_stream;
    let total_writers = args.streams; // 1 writer per stream

    // Barrier: all subscribers connect, then subscribers + writers all release
    // together so writers never send before any subscriber is live.
    // Subscribers cross the barrier UNCONDITIONALLY even on connect failure
    // (deadlock-safe, matching the mixed.rs pattern).
    let barrier_n = total_subscribers + total_writers;
    let ready_barrier = Arc::new(Barrier::new(barrier_n.max(1)));

    // Shared deadline — set by the first writer to cross the barrier.
    let deadline_cell = Arc::new(tokio::sync::OnceCell::<Instant>::new());

    // Shared histogram for all subscribers across all streams.
    let hist = Arc::new(Mutex::new(new_histogram()));
    let events_received = Arc::new(AtomicU64::new(0));

    let idle = Duration::from_secs(args.request_timeout_secs.max(10));
    let duration_secs = args.duration_secs;
    let rate = args.writer_rate.max(1);

    let mut handles = Vec::with_capacity(total_subscribers + total_writers);

    // --- SSE subscriber tasks (spawned first so they connect before writers) ---
    for stream_idx in 0..args.streams {
        let stream = stream_name(stream_idx);
        for sub_local_idx in 0..args.subscribers_per_stream {
            let backend = backend.clone();
            let stream = stream.clone();
            let barrier = ready_barrier.clone();
            let deadline_cell = deadline_cell.clone();
            let recv = events_received.clone();
            let hist = hist.clone();
            let sub_global_idx = stream_idx * args.subscribers_per_stream + sub_local_idx;
            handles.push(tokio::spawn(async move {
                if let Err(e) = run_subscriber_task(
                    &backend,
                    sub_global_idx,
                    &stream,
                    barrier,
                    deadline_cell,
                    recv,
                    hist,
                    idle,
                )
                .await
                {
                    tracing::warn!(
                        "subscriber failed: stream={stream} sub_local={sub_local_idx} error={e:#}"
                    );
                }
            }));
        }
    }

    let start = Instant::now();

    // --- Writer tasks (1 per stream; each waits at the barrier before first append) ---
    for stream_idx in 0..args.streams {
        let backend = backend.clone();
        let stream = stream_name(stream_idx);
        let barrier = ready_barrier.clone();
        let deadline_cell = deadline_cell.clone();
        handles.push(tokio::spawn(async move {
            run_writer_task(
                &backend,
                stream_idx,
                &stream,
                payload_bytes,
                rate,
                duration_secs,
                barrier,
                deadline_cell,
            )
            .await;
        }));
    }

    for h in handles {
        let _ = h.await;
    }

    let elapsed = start.elapsed();
    let elapsed_secs = elapsed.as_secs_f64();
    let ev_recv = events_received.load(Ordering::Relaxed);
    let aggregate_events_per_sec = ev_recv as f64 / elapsed_secs.max(1e-9);

    let locked_hist = hist.lock().await;
    let fan_out_latency_ms = summarize(&locked_hist);
    crate::dist::emit_hdr(&locked_hist, &format!("multi-fanout-{}", std::process::id()));

    Ok(MultiFanoutResult {
        scenario: "multi-fanout",
        api_style: args.api_style,
        target: args.target,
        streams: args.streams,
        subscribers_per_stream: args.subscribers_per_stream,
        writer_rate: args.writer_rate,
        duration_secs: args.duration_secs,
        payload_bytes: args.payload_bytes,
        elapsed_secs,
        events_received: ev_recv,
        aggregate_events_per_sec,
        fan_out_latency_ms,
    })
}

// ── Writer task ──────────────────────────────────────────────────────────────

async fn run_writer_task(
    backend: &Backend,
    stream_idx: usize,
    stream: &str,
    payload_bytes: usize,
    rate: u64,
    duration_secs: u64,
    barrier: Arc<Barrier>,
    deadline_cell: Arc<tokio::sync::OnceCell<Instant>>,
) {
    // Wait until all subscribers have established their SSE connections.
    barrier.wait().await;
    // First writer to cross sets the shared deadline.
    let deadline = *deadline_cell
        .get_or_init(|| async { Instant::now() + Duration::from_secs(duration_secs) })
        .await;

    let interval = Duration::from_micros(1_000_000 / rate.max(1));
    let mut next_at = Instant::now();
    let mut seq: u64 = 0;

    while Instant::now() < deadline {
        let now = Instant::now();
        if now < next_at {
            tokio::time::sleep(next_at - now).await;
        }
        next_at += interval;
        let payload = build_payload(seq, payload_bytes);
        let resp = backend
            .append_request(stream_idx, stream, &payload, None, "application/octet-stream")
            .send()
            .await;
        match resp {
            Ok(r) => {
                let s = r.status();
                if s.as_u16() == 503 || s.as_u16() == 429 {
                    tokio::time::sleep(Duration::from_millis(20)).await;
                }
            }
            Err(_) => {}
        }
        seq += 1;
    }
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

    // Attempt SSE connect — capture outcome but do NOT return yet.
    // The barrier MUST be crossed exactly once on BOTH success and failure paths
    // so that a failed subscriber does not leave all writers/subscribers hanging.
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

    // SSE connection attempted — cross the barrier unconditionally so writers
    // are never left hanging.  Successful subscribers are already listening;
    // failed subscribers simply won't record events.
    barrier.wait().await;

    // Now unwrap the connect result; on failure return cleanly.
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
                Some(end) => {
                    end.saturating_duration_since(Instant::now()) + Duration::from_secs(2)
                }
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
            while let Some(end_idx) = find_event_end(&buf) {
                let raw = buf.split_to(end_idx + 2).freeze();
                if let Some(p) = parse_sse_data(&raw) {
                    if let Some(sent_ns) = extract_send_ns_maybe_b64(&p) {
                        let now_ns = unix_nanos_now();
                        let lat_ns = now_ns.saturating_sub(sent_ns);
                        let us_u128 = lat_ns / 1000;
                        let us = us_u128.min(u128::from(local.high())) as u64;
                        if us > 0 {
                            let _ = local.record(us);
                        }
                    }
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

fn stream_name(idx: usize) -> String {
    format!("mf{:06}", idx)
}
