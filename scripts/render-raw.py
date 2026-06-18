#!/usr/bin/env python3
"""Render a DS-rust-only raw single-node report from GKE benchmark results.

Input: results-gke/*.json — coordinator MERGE summaries (MergeSummary shape):
    merged_count, p50_ms..p999_ms, max_ms,
    aggregate_ops_per_sec?   (multi-stream / mixed)
    aggregate_mb_per_sec?, bytes_received_total?   (catch-up)
    events_received_total?, events_per_sec?        (fan-out)
File naming:
    durable-<workload>.json
    durable-mixed-{write,fanout,read}.json
    sweep-durable-multi-stream-p<N>.json

Output: results/raw/durable.md  (also printed to stdout)

Usage: python3 scripts/render-raw.py [results_dir]
"""
import json, sys, pathlib, re

RESULTS = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "results-gke")
OUT_DIR = pathlib.Path("results/raw")
OUT_FILE = OUT_DIR / "durable.md"


def load(name):
    p = RESULTS / f"{name}.json"
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text())
    except Exception:
        return None


def cell_ops(d):
    if not d or d.get("aggregate_ops_per_sec") is None:
        return "-"
    return f"{d['aggregate_ops_per_sec']:,.0f}"


def cell_lat(d):
    if not d:
        return "-"
    return (f"{d.get('p50_ms', 0):.2f} / {d.get('p90_ms', 0):.2f} / "
            f"{d.get('p99_ms', 0):.2f} / {d.get('p999_ms', 0):.2f}")


def cell_count(d):
    return f"{d.get('merged_count', 0):,}" if d else "-"


out = [
    "# DS-rust — raw single-node benchmark results (GKE, MinIO-on-NVMe object tier)",
    "",
    "These are **raw DS-rust (durable-streams Rust server) numbers** from a single-node "
    "GKE deployment. They are not a cross-system comparison — see `results-gke/comparison.md` "
    "for the head-to-head table.",
    "",
]

# ---- multi-stream (write throughput) ----
ms = load("durable-multi-stream")
out += ["## multi-stream — write throughput", ""]
out += ["| metric | value |", "|---|---|"]
out += [
    f"| aggregate writes/s | {cell_ops(ms)} |",
    f"| p50/p90/p99/p999 ms | {cell_lat(ms)} |",
    f"| merged samples | {cell_count(ms)} |",
    "",
]

# ---- fan-out (SSE latency; ops/s N/A) ----
fo = load("durable-fan-out")
out += [
    "## fan-out — SSE end-to-end latency",
    "",
    "_ops/s is N/A for fan-out (the headline is the merged delivery latency); "
    "events/s shown for context._",
    "",
]
out += ["| metric | value |", "|---|---|"]
events_per_sec = (f"{fo['events_per_sec']:,.0f}"
                  if fo and fo.get("events_per_sec") is not None else "-")
events_total = (f"{fo['events_received_total']:,}"
                if fo and fo.get("events_received_total") is not None else "-")
out += [
    f"| events/s (Σpods) | {events_per_sec} |",
    f"| fan-out p50/p90/p99/p999 ms | {cell_lat(fo)} |",
    f"| events received | {events_total} |",
    "",
]

# ---- catch-up (replay) ----
cu = load("durable-catch-up")
out += ["## catch-up — replay throughput", ""]
out += ["| metric | value |", "|---|---|"]
mb_per_sec = (f"{cu['aggregate_mb_per_sec']:,.2f}"
              if cu and cu.get("aggregate_mb_per_sec") is not None else "-")
bytes_total = (f"{cu['bytes_received_total']:,}"
               if cu and cu.get("bytes_received_total") is not None else "-")
# catch-up: show p50/p99 only (merged_count is small — 50 replay ops)
p50 = f"{cu.get('p50_ms', 0):.3f}" if cu else "-"
p99 = f"{cu.get('p99_ms', 0):.3f}" if cu else "-"
out += [
    f"| aggregate MB/s (Σpods) | {mb_per_sec} |",
    f"| bytes received | {bytes_total} |",
    f"| p50/p99 ms | {p50} / {p99} |",
    "",
]

# ---- mixed (3 classes) ----
out += ["## mixed — per-class latency (write / fan-out / read)", ""]
out += ["| class | p50/p90/p99/p999 ms |", "|---|---|"]
for cls in ["write", "fanout", "read"]:
    md = load(f"durable-mixed-{cls}")
    out += [f"| {cls} | {cell_lat(md)} |"]
out += [""]

# ---- saturation sweep ----
sweep = []
for f in RESULTS.glob("sweep-durable-multi-stream-p*.json"):
    m = re.search(r"-p(\d+)\.json$", f.name)
    if m:
        d = load(f"sweep-durable-multi-stream-p{m.group(1)}")
        if d:
            sweep.append((int(m.group(1)), d))
sweep.sort(key=lambda x: x[0])

out += [
    "## saturation curve — DS-rust multi-stream vs client-fleet pods",
    "",
    "_Sweep: client-fleet pods 2 → 4 → 8, all other parameters held constant._",
    "",
]
if sweep:
    out += ["| client pods | aggregate writes/s | p99 ms | p999 ms | merged samples |",
            "|---|---|---|---|---|"]
    for p, d in sweep:
        out += [
            f"| {p} | {cell_ops(d)} | {d.get('p99_ms', 0):.2f} | "
            f"{d.get('p999_ms', 0):.2f} | {d.get('merged_count', 0):,} |"
        ]
    if len(sweep) >= 2:
        first_ops = sweep[0][1].get("aggregate_ops_per_sec") or 0
        last_ops = sweep[-1][1].get("aggregate_ops_per_sec") or 0
        trend = "rising" if last_ops > first_ops * 1.1 else "plateauing"
        out += [
            "",
            f"_Throughput is **{trend}** from {sweep[0][0]}→{sweep[-1][0]} pods "
            f"({first_ops:,.0f} → {last_ops:,.0f} writes/s)._",
        ]
else:
    out += ["_(no sweep results found)_"]
out += [""]

# ---- disclosures ----
out += [
    "## Disclosures",
    "",
    "- **Single-node deployment** — DS-rust server runs as a single pod on an "
    "`n2d-standard-8` GKE node (8 vCPU, 32 GB RAM). These numbers reflect "
    "single-node capacity only; multi-node scale-out is deferred to Phase 3.",
    "- **Object tier = in-cluster MinIO on local NVMe** — near-best-case for the "
    "cold tier (low latency, no cross-AZ hop); NOT representative of real cloud S3. "
    "Absolute numbers would be lower against a remote S3 endpoint.",
    "- **Group-commit durability** — writes are group-committed before "
    "acknowledgement and offloaded to the S3-compatible tier; this is the same "
    "durability posture used in the cross-system comparison.",
    "- **These are RAW DS-rust numbers** — not a cross-system claim. For "
    "head-to-head comparisons with ursula and S2 Lite, see "
    "`results-gke/comparison.md`.",
    "- **Latencies are HDR-merged** across all client-fleet pods; throughput sums "
    "each pod's headline figure.",
    "",
]

text = "\n".join(out)
OUT_DIR.mkdir(parents=True, exist_ok=True)
OUT_FILE.write_text(text)
print(text)
