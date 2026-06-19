#!/usr/bin/env python3
"""Render a Phase-1 raw-power benchmark report from gke-rawpower.sh results.

Input layout:
    results/rawpower/<RUN_ID>/<cell>/rep<N>/merged.json    -- coordinator HDR merge
    results/rawpower/<RUN_ID>/<cell>/rep<N>/samples.csv    -- ts_ms,rss_bytes,cpu_ticks
    results/rawpower/<RUN_ID>/<cell>/rep<N>/verdict.txt    -- key=value pairs

Cell naming (from gke-rawpower.sh):
    reads-cpu<C>-size<S>-conn<K>
    append-cpu<C>-conn<K>-<body_mode>
    append-splice-cpu<C>-conn<K>-binary-1m
    reads-cold-cpu<C>-size1m-conn<K>
    fanout-cpu<C>-subs<N>

Output: <run_dir>/report.md (also printed to stdout)

Usage:
    python3 scripts/render-rawpower.py [results/rawpower/<RUN_ID>]
    (defaults to the newest subdirectory under results/rawpower/)
"""
import pathlib, re, sys
from render_common import *  # shared loaders/formatters/aggregation

# ---------------------------------------------------------------------------
# Locate the run directory
# ---------------------------------------------------------------------------

RAWPOWER_ROOT = pathlib.Path("results/rawpower")

if len(sys.argv) > 1:
    run_dir = pathlib.Path(sys.argv[1])
else:
    candidates = [p for p in RAWPOWER_ROOT.iterdir() if p.is_dir()] if RAWPOWER_ROOT.exists() else []
    if not candidates:
        sys.exit("No run directory found under results/rawpower/ and none given on command line.")
    run_dir = sorted(candidates)[-1]

if not run_dir.exists():
    sys.exit(f"Run directory not found: {run_dir}")

OUT_FILE = run_dir / "report.md"

# ---------------------------------------------------------------------------
# Discover and parse cell directories
# ---------------------------------------------------------------------------

cell_dirs = sorted(
    [p for p in run_dir.iterdir() if p.is_dir() and not p.name.startswith(".")],
    key=lambda p: p.name,
)

# Build a dict: cell_name -> aggregate dict
cells = {}
for cd in cell_dirs:
    agg = aggregate_cell(cd)
    if agg:
        cells[cd.name] = agg

# Classify cells by scenario prefix
reads_cells   = {k: v for k, v in cells.items() if re.match(r"reads-cpu", k)}
append_cells  = {k: v for k, v in cells.items() if re.match(r"append-cpu", k)}
splice_cells  = {k: v for k, v in cells.items() if re.match(r"append-splice-", k)}
cold_cells    = {k: v for k, v in cells.items() if re.match(r"reads-cold-", k)}
fanout_cells  = {k: v for k, v in cells.items() if re.match(r"fanout-", k)}

# ---------------------------------------------------------------------------
# Parse cell name dimensions
# ---------------------------------------------------------------------------

_RE_READS   = re.compile(r"reads-cpu(\d+)-size(\d+)-conn(\d+)$")
_RE_APPEND  = re.compile(r"append-cpu(\d+)-conn(\d+)-(.+)$")
_RE_SPLICE  = re.compile(r"append-splice-cpu(\d+)-conn(\d+)-(.+)$")
_RE_COLD    = re.compile(r"reads-cold-cpu(\d+)-size(\w+)-conn(\d+)$")
_RE_FANOUT  = re.compile(r"fanout-cpu(\d+)-subs(\d+)$")


def dims_reads(name):
    m = _RE_READS.match(name)
    return (int(m.group(1)), int(m.group(2)), int(m.group(3))) if m else (0, 0, 0)


def dims_append(name):
    m = _RE_APPEND.match(name)
    return (int(m.group(1)), int(m.group(2)), m.group(3)) if m else (0, 0, "")


def dims_fanout(name):
    m = _RE_FANOUT.match(name)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)


# ---------------------------------------------------------------------------
# Build the report
# ---------------------------------------------------------------------------

out = [
    "# DS-rust — Phase 1 raw-power benchmark report",
    "",
    f"Run directory: `{run_dir}`",
    "",
    "> **Headroom verdict key:**",
    "> - `server_bound ✓` — server CPU was ≥ 90 % of its allocation; this is the trustworthy ceiling.",
    "> - `⚠️ client_capped` — server still had headroom; the number is a lower bound, NOT DS's ceiling.",
    "> - Median ± CV% shown where REPEATS = 3 (slow profile).",
    "",
]

# ============================================================================
# Section 1: Reads — size × conn → throughput, CPU%, p99
# ============================================================================

if reads_cells:
    out += [
        "## 1. Reads — throughput by message size × connections",
        "",
        "_ops/s = aggregate reads/s across all client pods. CPU% from sidecar samples.csv._",
        "",
        "| cell | cpu_cores | size_bytes | conns | reads/s | CPU% (sidecar) | p99 ms | verdict |",
        "|------|-----------|-----------|-------|---------|---------------|--------|---------|",
    ]
    for name in sorted(reads_cells, key=lambda k: dims_reads(k)):
        c = reads_cells[name]
        cpu_c, size, conn = dims_reads(name)
        out.append(
            f"| {name} | {cpu_c} | {size:,} | {conn} | "
            f"{ops_with_cv(c['ops'], c.get('ops_cv'))} | "
            f"{cpu_with_cv(c['cpu_pct'], c.get('cpu_cv'))} | "
            f"{fmt_ms(c['p99'])} | "
            f"{verdict_annotation(c['verdict'])} |"
        )
    out.append("")

# ============================================================================
# Section 2: Read scaling by server cores (efficiency view)
# ============================================================================

# Group reads cells by (size, conn) and pivot across cpu_cores
if reads_cells:
    # Find all unique (size, conn) combos and all cpu values
    all_cpus = sorted(set(dims_reads(n)[0] for n in reads_cells))
    all_sc   = sorted(set((dims_reads(n)[1], dims_reads(n)[2]) for n in reads_cells))

    if len(all_cpus) > 1:
        out += [
            "## 2. Read scaling by server cores",
            "",
            "_reads/s and CPU% per server core budget (same size×conn point). "
            "Efficiency = reads/s per core._",
            "",
        ]
        for (size, conn) in all_sc:
            out.append(f"### size={size:,} B, conn={conn}")
            out.append("")
            out.append("| cpu_cores | reads/s | CPU% | efficiency (reads/s/core) | verdict |")
            out.append("|-----------|---------|------|--------------------------|---------|")
            for cpu_c in all_cpus:
                cname = f"reads-cpu{cpu_c}-size{size}-conn{conn}"
                c = reads_cells.get(cname)
                if c:
                    eff = f"{c['ops'] / cpu_c:,.0f}" if c["ops"] is not None else "-"
                    out.append(
                        f"| {cpu_c} | {fmt_ops(c['ops'])} | {fmt_pct(c['cpu_pct'])} | "
                        f"{eff} | {verdict_annotation(c['verdict'])} |"
                    )
                else:
                    out.append(f"| {cpu_c} | - | - | - | - |")
            out.append("")

# ============================================================================
# Section 3: Appends — conn × body-mode → appends/s, CPU%, p99
# ============================================================================

if append_cells:
    out += [
        "## 3. Appends — throughput by connections × body mode",
        "",
        "_appends/s = aggregate appends/s. disk MB/s = server's actual /proc/io write_bytes "
        "rate (ground truth). CPU% from sidecar._",
        "",
        "| cell | cpu_cores | conns | body_mode | appends/s | disk MB/s | CPU% (sidecar) | p99 ms | verdict |",
        "|------|-----------|-------|-----------|----------|-----------|---------------|--------|---------|",
    ]
    for name in sorted(append_cells, key=lambda k: dims_append(k)):
        c = append_cells[name]
        cpu_c, conn, body = dims_append(name)
        out.append(
            f"| {name} | {cpu_c} | {conn} | {body} | "
            f"{ops_with_cv(c['ops'], c.get('ops_cv'))} | "
            f"{_dash(c.get('disk_mbps'), '{:.0f}')} | "
            f"{cpu_with_cv(c['cpu_pct'], c.get('cpu_cv'))} | "
            f"{fmt_ms(c['p99'])} | "
            f"{verdict_annotation(c['verdict'])} |"
        )
    out.append("")

# ============================================================================
# Section 4: Byte vs JSON (body mode comparison within same cpu/conn)
# ============================================================================

body_modes = ["binary", "json-single", "json-array"]
all_append_cpus = sorted(set(dims_append(n)[0] for n in append_cells))
all_append_conns = sorted(set(dims_append(n)[1] for n in append_cells))

has_multi_body = any(
    f"append-cpu{cpu_c}-conn{conn}-{bm}" in append_cells
    for cpu_c in all_append_cpus
    for conn in all_append_conns
    for bm in body_modes
    if sum(1 for bm2 in body_modes if f"append-cpu{cpu_c}-conn{conn}-{bm2}" in append_cells) > 1
)

if has_multi_body and append_cells:
    out += [
        "## 4. Byte vs JSON — body mode throughput comparison",
        "",
        "_Same cpu/conn, different body modes. json-array includes records/s (×10 events per op)._",
        "",
    ]
    for cpu_c in all_append_cpus:
        for conn in all_append_conns:
            available = [bm for bm in body_modes if f"append-cpu{cpu_c}-conn{conn}-{bm}" in append_cells]
            if len(available) < 2:
                continue
            out.append(f"### cpu={cpu_c} cores, conn={conn}")
            out.append("")
            out.append("| body_mode | appends/s | records/s (json-array) | CPU% | verdict |")
            out.append("|-----------|----------|----------------------|------|---------|")
            for bm in body_modes:
                cname = f"append-cpu{cpu_c}-conn{conn}-{bm}"
                c = append_cells.get(cname)
                if c:
                    # For json-array, events_sec may be set (10 records/op)
                    recs = "-"
                    if bm == "json-array" and c.get("events_sec") is not None:
                        recs = fmt_ops(c["events_sec"])
                    elif bm == "json-array" and c.get("ops") is not None:
                        recs = f"{c['ops'] * 10:,.0f} (est. ×10)"
                    out.append(
                        f"| {bm} | {fmt_ops(c['ops'])} | {recs} | "
                        f"{fmt_pct(c['cpu_pct'])} | {verdict_annotation(c['verdict'])} |"
                    )
                else:
                    out.append(f"| {bm} | - | - | - | - |")
            out.append("")

# ============================================================================
# Section 5: Splice — 1MB binary with/without --splice-appends
# ============================================================================

if splice_cells:
    out += [
        "## 5. Splice — 1 MB binary appends with/without --splice-appends",
        "",
        "_CPU lever: splice should reduce kernel copy overhead for large payloads._",
        "",
        "| cell | cpu_cores | conns | appends/s | throughput | CPU% (sidecar) | p99 ms | verdict |",
        "|------|-----------|-------|----------|------------|---------------|--------|---------|",
    ]
    # Also include standard 1MB append cells if present for comparison
    baseline_1m = {k: v for k, v in append_cells.items() if "1m" in k or "1048576" in k}
    combined = {**baseline_1m, **splice_cells}
    for name in sorted(combined):
        c = combined[name]
        m = _RE_SPLICE.match(name) or _RE_APPEND.match(name)
        if m:
            cpu_c, conn = int(m.group(1)), int(m.group(2))
        else:
            cpu_c, conn = "-", "-"
        out.append(
            f"| {name} | {cpu_c} | {conn} | "
            f"{fmt_ops(c['ops'])} | "
            f"{fmt_mb(c['bytes_sec'])} | "
            f"{fmt_pct(c['cpu_pct'])} | "
            f"{fmt_ms(c['p99'])} | "
            f"{verdict_annotation(c['verdict'])} |"
        )
    out.append("")

# ============================================================================
# Section 6: Cold-tier read — throughput MB/s or GB/s
# ============================================================================

if cold_cells:
    out += [
        "## 6. Cold-tier read — replay from object store",
        "",
        "_--tier local: reads go through the cold tier (simulated S3-on-NVMe). "
        "Seed = 100 MB to exceed hot cache._",
        "",
        "| cell | cpu_cores | reads/s | throughput | CPU% (sidecar) | p99 ms | verdict |",
        "|------|-----------|---------|------------|---------------|--------|---------|",
    ]
    for name in sorted(cold_cells):
        c = cold_cells[name]
        m = _RE_COLD.match(name)
        cpu_c = int(m.group(1)) if m else "-"
        out.append(
            f"| {name} | {cpu_c} | {fmt_ops(c['ops'])} | "
            f"{fmt_mb(c['bytes_sec'])} | "
            f"{fmt_pct(c['cpu_pct'])} | "
            f"{fmt_ms(c['p99'])} | "
            f"{verdict_annotation(c['verdict'])} |"
        )
    out.append("")

# ============================================================================
# Section 7: Single-stream fan-out — subscribers → p99 delivery + events/s
# ============================================================================

if fanout_cells:
    out += [
        "## 7. Single-stream fan-out — delivery latency vs subscriber count",
        "",
        "_p99 = end-to-end delivery latency (writer → last subscriber). "
        "events/s = aggregate across all subscribers._",
        "",
        "| cell | cpu_cores | subscribers | events/s | p50 ms | p99 ms | p999 ms | verdict |",
        "|------|-----------|------------|---------|--------|--------|---------|---------|",
    ]
    for name in sorted(fanout_cells, key=lambda k: dims_fanout(k)):
        c = fanout_cells[name]
        cpu_c, subs = dims_fanout(name)
        # events/s: prefer aggregate_events_per_sec, fallback to ops
        evts = c.get("events_sec") or c.get("ops")
        out.append(
            f"| {name} | {cpu_c} | {subs} | "
            f"{fmt_ops(evts)} | "
            f"{fmt_ms(c['p50'])} | "
            f"{fmt_ms(c['p99'])} | "
            f"{fmt_ms(c['p999'])} | "
            f"{verdict_annotation(c['verdict'])} |"
        )
    out.append("")

# ============================================================================
# Summary: client_capped cells (headroom honesty overview)
# ============================================================================

capped = [(n, c) for n, c in cells.items() if c.get("verdict") in ("client_capped", "server_headroom")]
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
        "| cell | reads/s or appends/s | CPU% | parallelism |",
        "|------|---------------------|------|------------|",
    ]
    for name, c in sorted(capped):
        out.append(
            f"| {name} | {fmt_ops(c['ops'])} | {fmt_pct(c['cpu_pct'])} | "
            f"{c.get('parallelism') or '-'} |"
        )
    out.append("")

# ============================================================================
# Disclosures
# ============================================================================

out += [
    "## Disclosures",
    "",
    "- **Object tier = in-cluster MinIO on local NVMe** — near-best-case for the cold tier "
    "(low latency, no cross-AZ hop); not representative of remote cloud S3. "
    "Absolute cold-tier numbers would be lower against real cloud S3.",
    "- **Server CPU% from sidecar, not cgroup CPUUsageNSec** — the metrics sidecar polls "
    "`/proc/<pid>/stat` cpu_ticks at intervals; CPU% = Δcpu_ticks / CLK_TCK (100) / Δelapsed_s × 100. "
    "This is per-process wall-clock CPU%, not cgroup accounting.",
    "- **server_bound = trustworthy ceiling** — the headroom guard bumps client parallelism "
    "until the server consumes ≥ 90 % of its CPU allocation. Only server_bound cells reflect "
    "DS's true throughput ceiling. client_capped cells ran out of client pods before saturating "
    "the server — those numbers are lower bounds.",
    "- **Where we have server_bound numbers, they reflect DS's true ceiling** — which a "
    "3-core-wrk single-client run could not reach.",
    "- **Median + CV% for slow profile (REPEATS=3)** — per-cell median across 3 repeats; "
    "CV% = sample_stddev/mean × 100 (÷ N-1). High CV% (> 10 %) may indicate run-to-run instability.",
    "- **CLK_TCK = 100** assumed (standard Linux kernel default; verified via "
    "`getconf CLK_TCK` inside the container).",
    "",
]

# ---------------------------------------------------------------------------
# Write and print
# ---------------------------------------------------------------------------

text = "\n".join(out)
OUT_FILE.write_text(text)
print(text)
