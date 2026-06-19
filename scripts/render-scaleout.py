#!/usr/bin/env python3
"""Render a Phase-2 scale-out benchmark report from gke-scaleout.sh results.

Input layout:
    results/scaleout/<RUN_ID>/<cell>/rep<N>/merged.json    -- coordinator HDR merge
    results/scaleout/<RUN_ID>/<cell>/rep<N>/samples.csv    -- ts_ms,rss_bytes,cpu_ticks
    results/scaleout/<RUN_ID>/<cell>/rep<N>/verdict.txt    -- key=value pairs

Cell naming (from gke-scaleout.sh):
    ms-cpu<C>-n<N>                      multi-stream writes (N concurrent streams, C server CPUs)
    multi-fanout-cpu<C>-m<M>-s<S>       multi-fanout (M streams, S subscribers/stream, C server CPUs)

Output: <run_dir>/report.md (also printed to stdout)

Usage:
    python3 scripts/render-scaleout.py [results/scaleout/<RUN_ID>]
    (defaults to the newest subdirectory under results/scaleout/)
"""
import pathlib, re, sys
from render_common import *  # shared loaders/formatters/aggregation

# ---------------------------------------------------------------------------
# Locate the run directory
# ---------------------------------------------------------------------------

SCALEOUT_ROOT = pathlib.Path("results/scaleout")

if len(sys.argv) > 1:
    run_dir = pathlib.Path(sys.argv[1])
else:
    candidates = [p for p in SCALEOUT_ROOT.iterdir() if p.is_dir()] if SCALEOUT_ROOT.exists() else []
    if not candidates:
        sys.exit("No run directory found under results/scaleout/ and none given on command line.")
    run_dir = sorted(candidates)[-1]

if not run_dir.exists():
    sys.exit(f"Run directory not found: {run_dir}")

OUT_FILE = run_dir / "report.md"

# ---------------------------------------------------------------------------
# Cell name regexes and dimension parsers
# ---------------------------------------------------------------------------

_RE_MS      = re.compile(r"ms-cpu(\d+)-n(\d+)$")
_RE_FANOUT  = re.compile(r"multi-fanout-cpu(\d+)-m(\d+)-s(\d+)$")


def dims_ms(name):
    """(server_cpu, n_streams) or (0, 0) on no-match."""
    m = _RE_MS.match(name)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)


def dims_fanout(name):
    """(server_cpu, M, S) or (0, 0, 0) on no-match."""
    m = _RE_FANOUT.match(name)
    return (int(m.group(1)), int(m.group(2)), int(m.group(3))) if m else (0, 0, 0)


# ---------------------------------------------------------------------------
# Discover and parse cell directories
# ---------------------------------------------------------------------------

cell_dirs = sorted(
    [p for p in run_dir.iterdir() if p.is_dir() and not p.name.startswith(".")],
    key=lambda p: p.name,
)

cells = {}
for cd in cell_dirs:
    agg = aggregate_cell(cd)
    if agg:
        cells[cd.name] = agg

ms_cells     = {k: v for k, v in cells.items() if _RE_MS.match(k)}
fanout_cells = {k: v for k, v in cells.items() if _RE_FANOUT.match(k)}

# ---------------------------------------------------------------------------
# Build the report
# ---------------------------------------------------------------------------

out = [
    "# DS-rust — Phase 2 scale-out benchmark report",
    "",
    f"Run directory: `{run_dir}`",
    "",
    "> **Headroom verdict key:**",
    "> - `server_bound ✓` — server CPU was ≥ 90 % of its allocation; this is the trustworthy ceiling.",
    "> - `⚠️ client_capped` — server still had headroom; the number is a lower bound, NOT DS's ceiling.",
    "> - Median ± CV% shown where REPEATS ≥ 3.",
    "",
]

# ============================================================================
# Section 1: Write throughput + tail vs stream count (multi-stream)
# ============================================================================

if ms_cells:
    out += [
        "## 1. Write throughput + tail latency vs stream count",
        "",
        "_aggregate_ops_per_sec = total appends/s across all concurrent write streams. "
        "CPU% and RSS from the server metrics sidecar._",
        "",
        "| server_cpu | streams | aggregate_ops/s | p50 ms | p99 ms | p999 ms | merged_count | verdict |",
        "|------------|---------|----------------|--------|--------|---------|--------------|---------|",
    ]
    for name in sorted(ms_cells, key=lambda k: dims_ms(k)):
        c = ms_cells[name]
        cpu_c, n_streams = dims_ms(name)
        out.append(
            f"| {cpu_c} | {n_streams} | "
            f"{ops_with_cv(c['ops'], c.get('ops_cv'))} | "
            f"{fmt_ms(c['p50'])} | "
            f"{fmt_ms(c['p99'])} | "
            f"{fmt_ms(c['p999'])} | "
            f"{fmt_ops(c['merged_count'])} | "
            f"{verdict_annotation(c['verdict'])} |"
        )
    out.append("")

# ============================================================================
# Section 2: Multi-stream fan-out vs (M, S)
# ============================================================================

if fanout_cells:
    out += [
        "## 2. Multi-stream fan-out vs (M streams × S subscribers/stream)",
        "",
        "_aggregate_events_per_sec = total events delivered across all subscriber connections. "
        "p99 = end-to-end delivery latency (write → last subscriber)._",
        "",
        "| server_cpu | M streams | S subs/stream | events/s | p50 ms | p99 ms | p999 ms | verdict |",
        "|------------|-----------|--------------|---------|--------|--------|---------|---------|",
    ]
    for name in sorted(fanout_cells, key=lambda k: dims_fanout(k)):
        c = fanout_cells[name]
        cpu_c, M, S = dims_fanout(name)
        out.append(
            f"| {cpu_c} | {M} | {S} | "
            f"{ops_with_cv(c['events_sec'], c.get('events_cv'))} | "
            f"{fmt_ms(c['p50'])} | "
            f"{fmt_ms(c['p99'])} | "
            f"{fmt_ms(c['p999'])} | "
            f"{verdict_annotation(c['verdict'])} |"
        )
    out.append("")

# ============================================================================
# Section 3: Server RSS + CPU% vs stream count
# ============================================================================

all_resource_cells = {**ms_cells, **fanout_cells}

if all_resource_cells:
    out += [
        "## 3. Server RSS + CPU% vs stream count",
        "",
        "_Resource cost of scale-out: peak RSS (MiB) and mean CPU% from the server metrics sidecar. "
        "CPU% = Δcpu_ticks / CLK_TCK (100) / Δelapsed_s × 100._",
        "",
        "| cell | rss_max_mib | cpu_pct | verdict |",
        "|------|-------------|---------|---------|",
    ]
    # Sort: multi-stream cells first (by cpu, then n), then fanout cells (by cpu, M, S)
    ms_sorted     = sorted(ms_cells.keys(),     key=lambda k: dims_ms(k))
    fanout_sorted = sorted(fanout_cells.keys(), key=lambda k: dims_fanout(k))
    for name in ms_sorted + fanout_sorted:
        c = all_resource_cells[name]
        out.append(
            f"| {name} | "
            f"{fmt_mib(c['rss_max_mib'])} | "
            f"{cpu_with_cv(c['cpu_pct'], c.get('cpu_cv'))} | "
            f"{verdict_annotation(c['verdict'])} |"
        )
    out.append("")

# ============================================================================
# Headroom honesty summary
# ============================================================================

capped      = [(n, c) for n, c in cells.items() if c.get("verdict") in ("client_capped", "server_headroom")]
server_bound = [(n, c) for n, c in cells.items() if c.get("verdict") == "server_bound"]

out += [
    "## Headroom honesty summary",
    "",
    f"- **server_bound cells:** {len(server_bound)} — these reflect DS's true ceiling.",
    f"- **client_capped cells:** {len(capped)} — these are lower bounds; DS could do more.",
    "",
]

if capped:
    out += [
        "### ⚠️ Client-capped cells (numbers are lower bounds)",
        "",
        "| cell | ops/s or events/s | CPU% | parallelism |",
        "|------|-------------------|------|------------|",
    ]
    for name, c in sorted(capped):
        throughput = fmt_ops(c["ops"]) if c.get("ops") is not None else fmt_ops(c.get("events_sec"))
        out.append(
            f"| {name} | {throughput} | {fmt_pct(c['cpu_pct'])} | "
            f"{c.get('parallelism') or '-'} |"
        )
    out.append("")

# ============================================================================
# Disclosures
# ============================================================================

out += [
    "## Disclosures",
    "",
    "- **Single-node deployment** — DS-rust server runs as a single pod on a GKE node. "
    "These numbers reflect single-node concurrent-stream capacity; multi-node distribution "
    "is deferred to Phase 3.",
    "- **Modern NVMe storage** — the object tier is in-cluster MinIO on local NVMe "
    "(near-best-case; not representative of remote cloud S3). Cold-tier absolute numbers "
    "would be lower against real cloud S3.",
    "- **Fleet load generator** — writer pods are a decoupled client fleet; aggregate "
    "throughput sums each pod's headline figure. Sidecar samples RSS/CPU at intervals "
    "independently of the HDR merge window.",
    "- **Server CPU% from sidecar** — `/proc/<pid>/stat` cpu_ticks polled at intervals; "
    "CPU% = Δcpu_ticks / CLK_TCK (100) / Δelapsed_s × 100. Per-process wall-clock CPU%, "
    "not cgroup accounting.",
    "- **server_bound = trustworthy ceiling** — the headroom guard bumps client parallelism "
    "until server CPU ≥ 90 % of its allocation. Only `server_bound ✓` cells reflect DS's "
    "true scale-out ceiling. `⚠️ client_capped` cells are lower bounds.",
    "- **Median + CV% for slow profile (REPEATS ≥ 3)** — per-cell median across repeats; "
    "CV% = sample_stddev/mean × 100 (÷ N-1). High CV% (> 10 %) may indicate run-to-run instability.",
    "- **CLK_TCK = 100** assumed (standard Linux kernel default).",
    "",
]

# ---------------------------------------------------------------------------
# Write and print
# ---------------------------------------------------------------------------

text = "\n".join(out)
OUT_FILE.write_text(text)
print(text)
