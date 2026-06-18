use anyhow::{Context, Result};
use hdrhistogram::serialization::{Deserializer, Serializer, V2Serializer};
use hdrhistogram::Histogram;
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
