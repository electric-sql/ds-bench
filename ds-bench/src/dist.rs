use anyhow::{Context, Result};
use hdrhistogram::serialization::{Deserializer, Serializer, V2Serializer};
use hdrhistogram::Histogram;
use serde::Serialize;
use std::path::Path;

/// If DS_BENCH_HDR_OUT is set, serialize `hist` (HdrHistogram V2) to
/// `{DS_BENCH_HDR_OUT}/{label}.hdr`. When DS_BENCH_INSTANCE is also set and
/// non-empty the file is `{DS_BENCH_HDR_OUT}/{label}-{instance}.hdr` so that
/// multiple fleet pods writing to a shared PVC each produce a distinct file.
/// Additive: callers ignore failures so a missing/unwritable sink never affects
/// the measured run.
pub fn emit_hdr(hist: &Histogram<u64>, label: &str) {
    let Ok(dir) = std::env::var("DS_BENCH_HDR_OUT") else { return };
    let filename = match std::env::var("DS_BENCH_INSTANCE").ok().filter(|s| !s.is_empty()) {
        Some(instance) => format!("{label}-{instance}.hdr"),
        None => format!("{label}.hdr"),
    };
    let path = Path::new(&dir).join(filename);
    let mut buf = Vec::new();
    if V2Serializer::new().serialize(hist, &mut buf).is_ok() {
        let _ = std::fs::create_dir_all(&dir);
        let _ = std::fs::write(&path, &buf);
    }
}

/// Merge every `*.hdr` file in `dir` into one histogram (exact, lossless).
/// When `label_prefix` is `Some(prefix)`, only files whose name starts with
/// that prefix are included (e.g. `"mixed-write"` skips fanout/read files).
/// When `label_prefix` is `None` all `*.hdr` files are merged (original behaviour).
pub fn merge_dir(dir: &Path) -> Result<Histogram<u64>> {
    merge_dir_filtered(dir, None)
}

pub fn merge_dir_filtered(dir: &Path, label_prefix: Option<&str>) -> Result<Histogram<u64>> {
    let mut merged = Histogram::<u64>::new_with_bounds(1, 60_000_000, 3)
        .context("alloc merged histogram")?;
    merged.auto(true);
    let mut de = Deserializer::new();
    for entry in std::fs::read_dir(dir).context("read hdr dir")? {
        let path = entry?.path();
        if path.extension().and_then(|e| e.to_str()) != Some("hdr") { continue; }
        // Apply optional prefix filter on the file stem (filename without extension).
        if let Some(prefix) = label_prefix {
            let stem = path
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("");
            if !stem.starts_with(prefix) {
                continue;
            }
        }
        let bytes = std::fs::read(&path).with_context(|| format!("read {path:?}"))?;
        let h: Histogram<u64> = de
            .deserialize(&mut std::io::Cursor::new(bytes))
            .map_err(|e| anyhow::anyhow!("deserialize {path:?}: {e:?}"))?;
        merged.add(&h).map_err(|e| anyhow::anyhow!("merge {path:?}: {e:?}"))?;
    }
    Ok(merged)
}

/// Per-workload headline metrics, summed across every per-pod JSON in the
/// results dir. Each workload has a *different* right headline:
///   * multi-stream / mixed → summed `aggregate_ops_per_sec` (writes/s)
///   * catch-up             → summed `aggregate_mb_per_sec` + `bytes_received_total`
///   * fan-out              → ops/s is N/A (latency is the headline); we instead
///                            sum `events_received` → `events_per_sec` over duration
///
/// Fields are `Option` so the JSON omits / nulls metrics that don't apply to a
/// workload rather than emitting a misleading `0`. The workload is auto-detected
/// from each per-pod JSON's `scenario` field; no flag required.
#[derive(Serialize, Default)]
pub struct MergeSummary {
    pub merged_count: u64,
    pub p50_ms: f64,
    pub p90_ms: f64,
    pub p99_ms: f64,
    pub p999_ms: f64,
    pub max_ms: f64,
    /// Summed writes/sec — multi-stream / mixed only. `None` (null/omitted) for
    /// fan-out and catch-up, where ops/s is not the headline.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub aggregate_ops_per_sec: Option<f64>,
    /// Summed MB/sec — catch-up only.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub aggregate_mb_per_sec: Option<f64>,
    /// Total bytes received — catch-up only.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bytes_received_total: Option<u64>,
    /// Total events received — fan-out only.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub events_received_total: Option<u64>,
    /// Events/sec (events_received_total / max per-pod duration) — fan-out only.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub events_per_sec: Option<f64>,
    /// Summed aggregate_events_per_sec — multi-fanout only.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub aggregate_events_per_sec: Option<f64>,
    /// Summed bytes/sec — reads scenario only (cold-tier GB/s, splice MB/s).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bytes_per_sec: Option<f64>,
}

/// Accumulators built from scanning the per-pod JSONs in the results dir.
#[derive(Default)]
struct HeadlineAcc {
    saw_ops: bool,
    ops: f64,
    saw_catchup: bool,
    mb_per_sec: f64,
    bytes_received: u64,
    saw_fanout: bool,
    events_received: u64,
    max_duration_secs: f64,
    saw_multi_fanout: bool,
    multi_fanout_events_per_sec: f64,
    /// Summed bytes/sec from reads pods (bytes_per_sec field in per-pod JSON).
    saw_reads: bool,
    reads_bytes_per_sec: f64,
}

fn scan_headlines(results_dir: Option<&Path>) -> HeadlineAcc {
    let mut acc = HeadlineAcc::default();
    let Some(dir) = results_dir else { return acc };
    let Ok(rd) = std::fs::read_dir(dir) else { return acc };
    for entry in rd.flatten() {
        let p = entry.path();
        if p.extension().and_then(|e| e.to_str()) != Some("json") { continue; }
        let Ok(txt) = std::fs::read_to_string(&p) else { continue };
        let Ok(v) = serde_json::from_str::<serde_json::Value>(&txt) else { continue };
        let scenario = v.get("scenario").and_then(|x| x.as_str()).unwrap_or("");
        if scenario.starts_with("catch-up") {
            acc.saw_catchup = true;
            acc.mb_per_sec += v.get("aggregate_mb_per_sec").and_then(|x| x.as_f64()).unwrap_or(0.0);
            acc.bytes_received += v.get("bytes_received_total").and_then(|x| x.as_u64()).unwrap_or(0);
        } else if scenario == "fanout" {
            acc.saw_fanout = true;
            acc.events_received += v.get("events_received").and_then(|x| x.as_u64()).unwrap_or(0);
            let d = v
                .get("duration_secs")
                .and_then(|x| x.as_f64())
                .or_else(|| v.get("elapsed_secs").and_then(|x| x.as_f64()))
                .unwrap_or(0.0);
            if d > acc.max_duration_secs {
                acc.max_duration_secs = d;
            }
        } else if scenario == "multi-fanout" {
            acc.saw_multi_fanout = true;
            acc.multi_fanout_events_per_sec += v
                .get("aggregate_events_per_sec")
                .and_then(|x| x.as_f64())
                .unwrap_or(0.0);
        } else if scenario == "reads" {
            // Reads: collect both ops/s (for the headline reads/s counter) and
            // bytes/s (for cold-tier GB/s and splice MB/s columns in the report).
            if let Some(ops) = v.get("aggregate_ops_per_sec").and_then(|x| x.as_f64()) {
                acc.saw_ops = true;
                acc.ops += ops;
            }
            if let Some(bps) = v.get("bytes_per_sec").and_then(|x| x.as_f64()) {
                acc.saw_reads = true;
                acc.reads_bytes_per_sec += bps;
            }
        } else {
            // multi-stream-write / mixed (and any future ops/s workload).
            if let Some(ops) = v.get("aggregate_ops_per_sec").and_then(|x| x.as_f64()) {
                acc.saw_ops = true;
                acc.ops += ops;
            }
        }
    }
    acc
}

pub fn merge_summary(hdr_dir: &Path, results_dir: Option<&Path>) -> Result<MergeSummary> {
    merge_summary_filtered(hdr_dir, results_dir, None)
}

pub fn merge_summary_filtered(
    hdr_dir: &Path,
    results_dir: Option<&Path>,
    label_prefix: Option<&str>,
) -> Result<MergeSummary> {
    let h = merge_dir_filtered(hdr_dir, label_prefix)?;
    let ms = |v: u64| (v as f64) / 1000.0;
    let acc = scan_headlines(results_dir);
    // Pick the headline(s) by which workload's per-pod JSONs we actually saw.
    // catch-up and fan-out take precedence (they never carry ops/s); ops/s is
    // multi-stream/mixed. A results dir holds one workload's pods at a time.
    let (aggregate_ops_per_sec, aggregate_mb_per_sec, bytes_received_total,
         events_received_total, events_per_sec, aggregate_events_per_sec,
         bytes_per_sec) = if acc.saw_catchup {
        (None, Some(acc.mb_per_sec), Some(acc.bytes_received), None, None, None, None)
    } else if acc.saw_fanout {
        let eps = if acc.max_duration_secs > 0.0 {
            Some(acc.events_received as f64 / acc.max_duration_secs)
        } else {
            None
        };
        (None, None, None, Some(acc.events_received), eps, None, None)
    } else if acc.saw_multi_fanout {
        (None, None, None, None, None, Some(acc.multi_fanout_events_per_sec), None)
    } else if acc.saw_ops {
        // reads scenario: also carry bytes_per_sec when available.
        let bps = if acc.saw_reads { Some(acc.reads_bytes_per_sec) } else { None };
        (Some(acc.ops), None, None, None, None, None, bps)
    } else {
        // No per-pod JSON (e.g. tests merging raw .hdr only): omit all headlines.
        (None, None, None, None, None, None, None)
    };
    Ok(MergeSummary {
        merged_count: h.len(),
        p50_ms: ms(h.value_at_quantile(0.5)),
        p90_ms: ms(h.value_at_quantile(0.9)),
        p99_ms: ms(h.value_at_quantile(0.99)),
        p999_ms: ms(h.value_at_quantile(0.999)),
        max_ms: ms(h.max()),
        aggregate_ops_per_sec,
        aggregate_mb_per_sec,
        bytes_received_total,
        events_received_total,
        events_per_sec,
        aggregate_events_per_sec,
        bytes_per_sec,
    })
}

#[derive(clap::Args, Debug, Clone)]
pub struct HdrMergeArgs {
    /// Directory containing per-pod *.hdr files.
    #[arg(long)]
    pub hdr_dir: String,
    /// Optional directory of per-pod *.json results (sums aggregate_ops_per_sec).
    #[arg(long)]
    pub results_dir: Option<String>,
    /// When set, only merge *.hdr files whose filename starts with this prefix.
    /// Use e.g. "mixed-write", "mixed-fanout", "mixed-read" to get per-class
    /// percentiles for the mixed workload.  When unset, all *.hdr files are
    /// merged (original behaviour — multi-stream/fan-out/catch-up unaffected).
    #[arg(long)]
    pub label_prefix: Option<String>,
}

pub fn run_merge(args: HdrMergeArgs) -> Result<String> {
    let results = args.results_dir.as_ref().map(Path::new);
    let prefix = args.label_prefix.as_deref();
    let summary = merge_summary_filtered(Path::new(&args.hdr_dir), results, prefix)?;
    Ok(serde_json::to_string_pretty(&summary)?)
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    /// A reads per-pod JSON that carries bytes_per_sec must contribute that value
    /// to the merged summary via scan_headlines.
    #[test]
    fn reads_bytes_per_sec_is_merged() {
        let dir = std::env::temp_dir()
            .join(format!("ds-bench-dist-test-{}-{}", std::process::id(), line!()));
        std::fs::create_dir_all(&dir).unwrap();

        // Write a minimal per-pod JSON for the reads scenario.
        let json = r#"{
            "scenario": "reads",
            "aggregate_ops_per_sec": 500.0,
            "bytes_per_sec": 1000.0,
            "elapsed_secs": 10.0
        }"#;
        let mut f = std::fs::File::create(dir.join("pod0.json")).unwrap();
        f.write_all(json.as_bytes()).unwrap();

        let acc = scan_headlines(Some(&dir));
        let _ = std::fs::remove_dir_all(&dir); // cleanup (best effort)
        assert!(acc.saw_reads, "expected saw_reads=true");
        assert!(
            (acc.reads_bytes_per_sec - 1000.0).abs() < 1e-6,
            "expected reads_bytes_per_sec≈1000, got {}",
            acc.reads_bytes_per_sec
        );
        assert!(
            (acc.ops - 500.0).abs() < 1e-6,
            "expected ops≈500, got {}",
            acc.ops
        );
    }
}
