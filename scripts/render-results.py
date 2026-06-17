#!/usr/bin/env python3
"""Render results/*.json into a markdown comparison table. Usage: render-results.py [results_dir]"""
import json, sys, pathlib

RESULTS = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "results")
SYSTEMS = ["durable", "ursula", "s2"]

def load(system, workload):
    p = RESULTS / f"{system}-{workload}.json"
    return json.loads(p.read_text()) if p.exists() else None

def first_present(results_dict):
    """Return the first non-None result across SYSTEMS (durable preferred, then others)."""
    for s in SYSTEMS:
        if results_dict.get(s):
            return results_dict[s]
    return {}

def lat(d):
    if not d: return ("-",) * 4
    l = d.get("latency_ms") or d.get("fan_out_latency_ms") or {}
    return (f"{l.get('p50_ms',0):.2f}", f"{l.get('p90_ms',0):.2f}",
            f"{l.get('p99_ms',0):.2f}", f"{l.get('p999_ms',0):.2f}")

def row(label, fn):
    return "| " + label + " | " + " | ".join(fn(s) for s in SYSTEMS) + " |"

out = ["# Single-node comparison: durable-streams vs ursula vs S2 Lite", ""]
hdr = "| metric | " + " | ".join(SYSTEMS) + " |"
sep = "|" + "---|" * (len(SYSTEMS) + 1)

ms = {s: load(s, "multi-stream") for s in SYSTEMS}
_ms = first_present(ms)
_ms_params = (f"_params: streams={_ms.get('streams','?')}, "
              f"duration={_ms.get('duration_secs','?')}s, "
              f"payload={_ms.get('payload_bytes','?')}B, "
              f"rate_per_stream={_ms.get('rate_per_stream','?')} (max)_")
out += ["## multi-stream (write throughput)", "", _ms_params, "", hdr, sep,
        row("aggregate ops/s", lambda s: f"{(ms[s] or {}).get('aggregate_ops_per_sec',0):.0f}"),
        row("p50/p90/p99/p999 ms", lambda s: " / ".join(lat(ms[s]))),
        row("ok / backpressure / err",
            lambda s: f"{(ms[s] or {}).get('counts',{}).get('ok',0)} / "
                      f"{(ms[s] or {}).get('counts',{}).get('backpressure',0)} / "
                      f"{(ms[s] or {}).get('counts',{}).get('other_err',0)}"), ""]

fo = {s: load(s, "fanout") for s in SYSTEMS}
_fo = first_present(fo)
_fo_params = (f"_params: subscribers={_fo.get('subscribers','?')}, "
              f"writer_rate={_fo.get('writer_rate','?')}, "
              f"duration={_fo.get('duration_secs','?')}s, "
              f"payload={_fo.get('payload_bytes','?')}B_")
out += ["## fan-out (SSE end-to-end latency)", "", _fo_params, "", hdr, sep,
        row("events received", lambda s: f"{(fo[s] or {}).get('events_received',0)}"),
        row("p50/p90/p99/p999 ms", lambda s: " / ".join(lat(fo[s]))), ""]

cu = {s: load(s, "catch-up") for s in SYSTEMS}
_cu = first_present(cu)
_cu_params = (f"_params: clients={_cu.get('clients','?')}, "
              f"pre_events={_cu.get('pre_events','?')}, "
              f"event_bytes={_cu.get('event_bytes','?')}B_")
out += ["## catch-up (replay throughput)", "",
        "_S2 Lite excluded from catch-up — see README (paginated, JSON-enveloped read, not comparable)._",
        "", _cu_params, "", hdr, sep,
        row("aggregate MB/s", lambda s: f"{cu[s]['aggregate_mb_per_sec']:.2f}" if cu[s] else "-"),
        row("bytes received", lambda s: f"{cu[s]['bytes_received_total']}" if cu[s] else "-"),
        row("stampede secs", lambda s: f"{cu[s]['stampede_elapsed_secs']:.2f}" if cu[s] else "-"),
        row("p50/p90/p99/p999 ms", lambda s: " / ".join(lat(cu[s])) if cu[s] else "-"), ""]

(RESULTS / "comparison.md").write_text("\n".join(out))
print("\n".join(out))
