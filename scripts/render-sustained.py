#!/usr/bin/env python3
"""Render a sustained-stream benchmark report from gke-sustained.sh results.

Input layout:
    results/sustained/<RUN_ID>/<N>/merged.json   -- coordinator HDR merge
    results/sustained/<RUN_ID>/<N>/samples.csv   -- ts_ms,rss_bytes,cpu_ticks sidecar

Output: <run_dir>/report.md  (also printed to stdout)

Usage:
    python3 scripts/render-sustained.py [results/sustained/<RUN_ID>]
    (defaults to the newest subdirectory under results/sustained/)
"""
import csv, json, sys, pathlib, math
from render_common import *  # shared loaders + CLK_TCK/MiB/fmt_mib

# ---------------------------------------------------------------------------
# Locate the run directory
# ---------------------------------------------------------------------------

SUSTAINED_ROOT = pathlib.Path("results/sustained")

if len(sys.argv) > 1:
    run_dir = pathlib.Path(sys.argv[1])
else:
    candidates = [p for p in SUSTAINED_ROOT.iterdir() if p.is_dir()] if SUSTAINED_ROOT.exists() else []
    if not candidates:
        sys.exit("No run directory found under results/sustained/ and none given on command line.")
    run_dir = sorted(candidates)[-1]

if not run_dir.exists():
    sys.exit(f"Run directory not found: {run_dir}")

OUT_FILE = run_dir / "report.md"

# ---------------------------------------------------------------------------
# Discover per-N subdirectories (numeric names = stream counts)
# ---------------------------------------------------------------------------

stream_dirs = sorted(
    [p for p in run_dir.iterdir() if p.is_dir() and p.name.isdigit()],
    key=lambda p: int(p.name),
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def rss_stats(samples):
    """Return (start_mib, max_mib, end_mib, slope_mib_per_min) or all None."""
    if not samples or len(samples) < 2:
        return None, None, None, None
    rss = [r for _, r, _ in samples]
    ts  = [t for t, _, _ in samples]
    start = rss[0] / MiB
    end   = rss[-1] / MiB
    peak  = max(rss) / MiB
    elapsed_min = (ts[-1] - ts[0]) / 60_000.0
    slope = (end - start) / elapsed_min if elapsed_min > 0 else 0.0
    return start, peak, end, slope


def cpu_stats(samples):
    """Derive CPU% from consecutive cpu_ticks deltas / CLK_TCK / elapsed_s.
    Returns (mean_pct, is_flat) where is_flat means stddev < 10 pp of mean."""
    if not samples or len(samples) < 2:
        return None, None
    pcts = []
    for i in range(1, len(samples)):
        dt_s = (samples[i][0] - samples[i-1][0]) / 1000.0
        if dt_s <= 0:
            continue
        dticks = samples[i][2] - samples[i-1][2]
        # cpu_ticks are cumulative; negative delta = wrap or reset, skip
        if dticks < 0:
            continue
        pcts.append(dticks / CLK_TCK / dt_s * 100.0)
    if not pcts:
        return None, None
    mean = sum(pcts) / len(pcts)
    variance = sum((p - mean) ** 2 for p in pcts) / len(pcts)
    stddev = math.sqrt(variance)
    is_flat = stddev < max(10.0, mean * 0.15)
    return mean, is_flat


# ---------------------------------------------------------------------------
# Build the report
# ---------------------------------------------------------------------------

out = [
    f"# DS-rust — sustained-stream benchmark report",
    "",
    f"Run directory: `{run_dir}`",
    "",
]

# ---- Section 1: Throughput + tail vs stream count -------------------------

out += [
    "## 1. Throughput + tail latency vs stream count",
    "",
    "| streams | aggregate_ops_per_sec | p50 ms | p99 ms | p999 ms | merged_samples |",
    "|---|---|---|---|---|---|",
]

for sd in stream_dirs:
    n = int(sd.name)
    d = load_merged(sd)
    if d:
        ops  = f"{d['aggregate_ops_per_sec']:,.0f}" if d.get("aggregate_ops_per_sec") is not None else "-"
        p50  = f"{d['p50_ms']:.2f}"  if d.get("p50_ms")  is not None else "-"
        p99  = f"{d['p99_ms']:.2f}"  if d.get("p99_ms")  is not None else "-"
        p999 = f"{d['p999_ms']:.2f}" if d.get("p999_ms") is not None else "-"
        cnt  = f"{d['merged_count']:,}" if d.get("merged_count") is not None else "-"
    else:
        ops = p50 = p99 = p999 = cnt = "-"
    out.append(f"| {n} | {ops} | {p50} | {p99} | {p999} | {cnt} |")

out.append("")

# ---- Section 2: Server memory vs stream count (RSS drift) -----------------

out += [
    "## 2. Server memory vs stream count (RSS drift)",
    "",
    "_RSS values in MiB. Slope = (rss\\_end − rss\\_start) / elapsed minutes._",
    "",
    "| streams | rss_start_mib | rss_max_mib | rss_end_mib | rss_slope_mib_per_min |",
    "|---|---|---|---|---|",
]

for sd in stream_dirs:
    n = int(sd.name)
    samples = load_samples(sd)
    if samples:
        start, peak, end, slope = rss_stats(samples)
        out.append(
            f"| {n} | {fmt_mib(start)} | {fmt_mib(peak)} | {fmt_mib(end)} | "
            f"{slope:+.3f} |"
        )
    else:
        out.append(f"| {n} | - | - | - | - |")

out.append("")

# ---- Section 3: CPU over time (steady-state check) ------------------------

out += [
    "## 3. CPU over time (steady-state check)",
    "",
    "_CPU% derived from consecutive cpu\\_ticks deltas ÷ CLK\\_TCK (100) ÷ elapsed seconds × 100._",
    "_Flat = stddev < max(10 pp, 15 % of mean)._",
    "",
]

for sd in stream_dirs:
    n = int(sd.name)
    samples = load_samples(sd)
    if samples:
        mean_pct, is_flat = cpu_stats(samples)
        if mean_pct is not None:
            stability = "flat (steady)" if is_flat else "variable"
            out.append(f"- **{n} streams**: mean CPU {mean_pct:.1f}% — {stability}")
        else:
            out.append(f"- **{n} streams**: CPU data insufficient")
    else:
        out.append(f"- **{n} streams**: no samples.csv")

out.append("")

# ---- Disclosures -----------------------------------------------------------

out += [
    "## Disclosures",
    "",
    "- **Single-node deployment** — DS-rust server runs as a single pod on a GKE node. "
    "These numbers reflect single-node sustained capacity only; multi-node scale-out is "
    "deferred to Phase 3.",
    "- **Load generated by the decoupled client fleet** — writer pods run independently "
    "of the server metrics sidecar; sidecar samples RSS/CPU at intervals and is not "
    "synchronised to the HDR merge window.",
    "- **Object/metrics caveats** — the object tier is in-cluster MinIO on local NVMe "
    "(near-best-case; not representative of remote cloud S3). Latencies are HDR-merged "
    "across all client-fleet pods; throughput sums each pod's headline figure.",
    "- **Per-pod latency-over-time snapshots are NOT yet collected** — the sidecar "
    "provides server RSS and CPU over time; the `sustained --snapshot-secs` per-pod "
    "latency time-series would require pod-log collection from every client pod. "
    "This is a follow-up item.",
    "- **RSS slope** is computed as a simple linear approximation: "
    "(rss\\_end − rss\\_start) / elapsed minutes. A positive slope indicates memory "
    "growth over the run; a near-zero slope indicates stable cardinality.",
    "- **CPU% computation** assumes `CLK_TCK = 100` (standard Linux). Each interval's "
    "CPU% is (Δcpu\\_ticks / 100) / elapsed\\_s × 100. The stability flag is a "
    "heuristic (stddev < max(10 pp, 15 % of mean)).",
    "",
]

# ---------------------------------------------------------------------------
# Write and print
# ---------------------------------------------------------------------------

text = "\n".join(out)
OUT_FILE.write_text(text)
print(text)
