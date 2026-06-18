#!/usr/bin/env python3
"""Render the Phase-2b.2 GKE matrix merged JSONs into results-gke/comparison.md.

Input: results-gke/*.json — each is a coordinator MERGE summary (the new
MergeSummary shape from ds-bench hdr-merge), NOT a single per-pod result:
    merged_count, p50_ms..p999_ms, max_ms,
    aggregate_ops_per_sec?   (multi-stream / mixed)
    aggregate_mb_per_sec?, bytes_received_total?   (catch-up)
    events_received_total?, events_per_sec?        (fan-out)
File naming (from gke-matrix.sh):
    <system>-<workload>.json                    e.g. durable-multi-stream.json
    <system>-mixed-{write,fanout,read}.json     mixed per-class
    sweep-durable-multi-stream-p<N>.json        saturation sweep points

Output: results-gke/comparison.md — single-node head-to-head tables, the durable
saturation curve, and the fairness/honesty disclosures.

Usage: render-gke.py [results_dir]
"""
import json, sys, pathlib, re

RESULTS = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "results-gke")
SYSTEMS = ["durable", "ursula", "s2"]
LABEL = {"durable": "DS-rust", "ursula": "ursula", "s2": "S2 Lite"}


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
    return (f"{d.get('p50_ms',0):.2f} / {d.get('p90_ms',0):.2f} / "
            f"{d.get('p99_ms',0):.2f} / {d.get('p999_ms',0):.2f}")


def cell_count(d):
    return f"{d.get('merged_count',0):,}" if d else "-"


def tbl_header():
    hdr = "| metric | " + " | ".join(LABEL[s] for s in SYSTEMS) + " |"
    sep = "|" + "---|" * (len(SYSTEMS) + 1)
    return [hdr, sep]


def row(label, vals):
    return "| " + label + " | " + " | ".join(vals) + " |"


out = ["# Phase 2b.2 — single-node head-to-head (GKE, MinIO-on-NVMe object tier)",
       "",
       "All systems run at **a single node** with matched durability (group-committed "
       "writes + an S3-compatible cold tier on the SAME in-cluster MinIO, which sits on "
       "the server node's local NVMe). Latencies are the EXACT cross-node HDR merge of "
       "every client-fleet pod; throughput sums each pod's headline. "
       f"DS-node is **SKIPPED** (Node server is a library — no entrypoint/env-config and "
       f"no S3 cold tier; see `gke/ds-node-SKIPPED.md`).",
       ""]

# ---- multi-stream (write throughput) ----
ms = {s: load(f"{s}-multi-stream") for s in SYSTEMS}
out += ["## multi-stream — write throughput", ""]
out += tbl_header()
out += [row("aggregate writes/s", [cell_ops(ms[s]) for s in SYSTEMS]),
        row("p50/p90/p99/p999 ms", [cell_lat(ms[s]) for s in SYSTEMS]),
        row("merged samples", [cell_count(ms[s]) for s in SYSTEMS]), ""]

# ---- fan-out (SSE latency; ops/s N/A) ----
fo = {s: load(f"{s}-fan-out") for s in SYSTEMS}
out += ["## fan-out — SSE end-to-end latency", "",
        "_ops/s is N/A for fan-out (the headline is the merged delivery latency); "
        "events/s shown for context._", ""]
out += tbl_header()
out += [row("fan-out p50/p90/p99/p999 ms", [cell_lat(fo[s]) for s in SYSTEMS]),
        row("events/s (Σpods)",
            [f"{fo[s]['events_per_sec']:,.0f}" if fo[s] and fo[s].get('events_per_sec') is not None else "-"
             for s in SYSTEMS]),
        row("events received", [f"{fo[s]['events_received_total']:,}"
            if fo[s] and fo[s].get('events_received_total') is not None else "-" for s in SYSTEMS]), ""]

# ---- catch-up (replay; S2 excluded) ----
cu = {s: load(f"{s}-catch-up") for s in SYSTEMS}
out += ["## catch-up — replay throughput", "",
        "_S2 Lite excluded from catch-up (paginated JSON-enveloped read, not comparable)._", ""]
out += tbl_header()
out += [row("aggregate MB/s (Σpods)",
            [f"{cu[s]['aggregate_mb_per_sec']:,.2f}" if cu[s] and cu[s].get('aggregate_mb_per_sec') is not None else "-"
             for s in SYSTEMS]),
        row("bytes received",
            [f"{cu[s]['bytes_received_total']:,}" if cu[s] and cu[s].get('bytes_received_total') is not None else "-"
             for s in SYSTEMS]),
        row("p50/p90/p99/p999 ms", [cell_lat(cu[s]) for s in SYSTEMS]), ""]

# ---- mixed (3 classes; S2 excluded) ----
out += ["## mixed — write / fan-out / read (per class)", "",
        "_S2 Lite excluded from mixed._", ""]
mh = "| class | metric | " + " | ".join(LABEL[s] for s in ["durable", "ursula"]) + " |"
out += [mh, "|---|---|---|---|"]
for cls in ["write", "fanout", "read"]:
    md = {s: load(f"{s}-mixed-{cls}") for s in ["durable", "ursula"]}
    out += [row("", [f"**{cls}**", "p50/p90/p99/p999 ms"]
                + [cell_lat(md[s]) for s in ["durable", "ursula"]]).replace("|  |", "|")]
out += [""]

# ---- saturation sweep (durable multi-stream vs client pods) ----
sweep = []
for p in sorted(int(m.group(1)) for f in RESULTS.glob("sweep-durable-multi-stream-p*.json")
                for m in [re.search(r"-p(\d+)\.json$", f.name)] if m):
    d = load(f"sweep-durable-multi-stream-p{p}")
    if d:
        sweep.append((p, d))
out += ["## saturation curve — DS-rust multi-stream vs client-fleet pods", "",
        "_The one sweep run (full payload×subscriber×system cartesian deferred for cost)._", ""]
if sweep:
    out += ["| client pods | aggregate writes/s | p99 ms | p999 ms | merged samples |",
            "|---|---|---|---|---|"]
    for p, d in sweep:
        out += [f"| {p} | {cell_ops(d)} | {d.get('p99_ms',0):.2f} | "
                f"{d.get('p999_ms',0):.2f} | {d.get('merged_count',0):,} |"]
    # crude plateau note
    if len(sweep) >= 2:
        first_ops = sweep[0][1].get("aggregate_ops_per_sec") or 0
        last_ops = sweep[-1][1].get("aggregate_ops_per_sec") or 0
        trend = "rising" if last_ops > first_ops * 1.1 else "plateauing"
        out += ["", f"_Throughput is **{trend}** from {sweep[0][0]}→{sweep[-1][0]} pods "
                f"({first_ops:,.0f} → {last_ops:,.0f} writes/s)._"]
else:
    out += ["_(no sweep results found)_"]
out += [""]

# ---- disclosures ----
out += ["## Disclosures (fairness / honesty)", "",
        "- **Object tier = in-cluster MinIO on local NVMe** — near-best-case for the "
        "cold tier (low latency, no cross-AZ hop); NOT representative of real cloud S3. "
        "It is identical for every system, so comparisons are fair, but absolute numbers "
        "would be lower against cloud S3.",
        "- **Matched single-node durability + group-commit symmetry** — every system "
        "group-commits writes and offloads to the same S3-compatible tier; no system is "
        "given a weaker-durability fast path.",
        "- **S2 is a different substrate** and is **excluded from catch-up and mixed** "
        "(its paginated JSON-enveloped read path is not comparable); it runs multi-stream "
        "+ fan-out only.",
        "- **ursula is single-node only.** Multi-node (1/3/5) is deferred to Phase 3 "
        "(durable-streams does not yet support multi-node), so this is a clean "
        "apples-to-apples single-node head-to-head with no multi-node honesty caveat.",
        "- **DS-node SKIPPED** — the Node/TS durable-streams server is a reference "
        "library (no standalone entrypoint, no env-based config, no S3 cold tier), so it "
        "cannot be made durability-matched. See `gke/ds-node-SKIPPED.md`.",
        "- **Deferred sweeps** — only one saturation sweep (DS-rust multi-stream, client "
        "pods 2→4→8) was run. The full payload×subscriber×system cartesian and ursula "
        "multi-node scale-out are deferred for cost.",
        ""]

text = "\n".join(out)
(RESULTS / "comparison.md").write_text(text)
print(text)
