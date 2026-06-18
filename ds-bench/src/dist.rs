use anyhow::{Context, Result};
use hdrhistogram::serialization::{Deserializer, Serializer, V2Serializer};
use hdrhistogram::Histogram;
use serde::Serialize;
use std::path::Path;

/// If DS_BENCH_HDR_OUT is set, serialize `hist` (HdrHistogram V2) to
/// `{DS_BENCH_HDR_OUT}/{label}.hdr`. Additive: callers ignore failures so a
/// missing/unwritable sink never affects the measured run.
pub fn emit_hdr(hist: &Histogram<u64>, label: &str) {
    let Ok(dir) = std::env::var("DS_BENCH_HDR_OUT") else { return };
    let path = Path::new(&dir).join(format!("{label}.hdr"));
    let mut buf = Vec::new();
    if V2Serializer::new().serialize(hist, &mut buf).is_ok() {
        let _ = std::fs::create_dir_all(&dir);
        let _ = std::fs::write(&path, &buf);
    }
}

/// Merge every `*.hdr` file in `dir` into one histogram (exact, lossless).
pub fn merge_dir(dir: &Path) -> Result<Histogram<u64>> {
    let mut merged = Histogram::<u64>::new_with_bounds(1, 60_000_000, 3)
        .context("alloc merged histogram")?;
    merged.auto(true);
    let mut de = Deserializer::new();
    for entry in std::fs::read_dir(dir).context("read hdr dir")? {
        let path = entry?.path();
        if path.extension().and_then(|e| e.to_str()) != Some("hdr") { continue; }
        let bytes = std::fs::read(&path).with_context(|| format!("read {path:?}"))?;
        let h: Histogram<u64> = de
            .deserialize(&mut std::io::Cursor::new(bytes))
            .map_err(|e| anyhow::anyhow!("deserialize {path:?}: {e:?}"))?;
        merged.add(&h).map_err(|e| anyhow::anyhow!("merge {path:?}: {e:?}"))?;
    }
    Ok(merged)
}

#[derive(Serialize)]
pub struct MergeSummary {
    pub merged_count: u64,
    pub p50_ms: f64,
    pub p90_ms: f64,
    pub p99_ms: f64,
    pub p999_ms: f64,
    pub max_ms: f64,
    pub aggregate_ops_per_sec: f64,
}

fn sum_ops(results_dir: Option<&Path>) -> f64 {
    let Some(dir) = results_dir else { return 0.0 };
    let mut total = 0.0;
    if let Ok(rd) = std::fs::read_dir(dir) {
        for entry in rd.flatten() {
            let p = entry.path();
            if p.extension().and_then(|e| e.to_str()) != Some("json") { continue; }
            if let Ok(txt) = std::fs::read_to_string(&p) {
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(&txt) {
                    total += v.get("aggregate_ops_per_sec").and_then(|x| x.as_f64()).unwrap_or(0.0);
                }
            }
        }
    }
    total
}

pub fn merge_summary(hdr_dir: &Path, results_dir: Option<&Path>) -> Result<MergeSummary> {
    let h = merge_dir(hdr_dir)?;
    let ms = |v: u64| (v as f64) / 1000.0;
    Ok(MergeSummary {
        merged_count: h.len(),
        p50_ms: ms(h.value_at_quantile(0.5)),
        p90_ms: ms(h.value_at_quantile(0.9)),
        p99_ms: ms(h.value_at_quantile(0.99)),
        p999_ms: ms(h.value_at_quantile(0.999)),
        max_ms: ms(h.max()),
        aggregate_ops_per_sec: sum_ops(results_dir),
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
}

pub fn run_merge(args: HdrMergeArgs) -> Result<String> {
    let results = args.results_dir.as_ref().map(Path::new);
    let summary = merge_summary(Path::new(&args.hdr_dir), results)?;
    Ok(serde_json::to_string_pretty(&summary)?)
}
