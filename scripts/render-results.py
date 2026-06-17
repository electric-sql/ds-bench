#!/usr/bin/env python3
"""Render results/*.json into a markdown comparison table. Usage: render-results.py [results_dir]"""
import json, sys, pathlib

RESULTS = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "results")
SYSTEMS = ["durable", "ursula"]

def load(system, workload):
    p = RESULTS / f"{system}-{workload}.json"
    return json.loads(p.read_text()) if p.exists() else None

def lat(d):
    if not d: return ("-",) * 4
    l = d.get("latency_ms") or d.get("fan_out_latency_ms") or {}
    return (f"{l.get('p50_ms',0):.2f}", f"{l.get('p90_ms',0):.2f}",
            f"{l.get('p99_ms',0):.2f}", f"{l.get('p999_ms',0):.2f}")

def row(label, fn):
    return "| " + label + " | " + " | ".join(fn(s) for s in SYSTEMS) + " |"

out = ["# Single-node comparison: durable-streams vs ursula", ""]
hdr = "| metric | " + " | ".join(SYSTEMS) + " |"
sep = "|" + "---|" * (len(SYSTEMS) + 1)

ms = {s: load(s, "multi-stream") for s in SYSTEMS}
out += ["## multi-stream (write throughput)", "", hdr, sep,
        row("aggregate ops/s", lambda s: f"{(ms[s] or {}).get('aggregate_ops_per_sec',0):.0f}"),
        row("p50/p90/p99/p999 ms", lambda s: " / ".join(lat(ms[s]))),
        row("ok / backpressure / err",
            lambda s: f"{(ms[s] or {}).get('counts',{}).get('ok',0)} / "
                      f"{(ms[s] or {}).get('counts',{}).get('backpressure',0)} / "
                      f"{(ms[s] or {}).get('counts',{}).get('other_err',0)}"), ""]

fo = {s: load(s, "fanout") for s in SYSTEMS}
out += ["## fan-out (SSE end-to-end latency)", "", hdr, sep,
        row("events received", lambda s: f"{(fo[s] or {}).get('events_received',0)}"),
        row("p50/p90/p99/p999 ms", lambda s: " / ".join(lat(fo[s]))), ""]

(RESULTS / "comparison.md").write_text("\n".join(out))
print("\n".join(out))
