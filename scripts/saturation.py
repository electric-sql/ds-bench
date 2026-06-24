#!/usr/bin/env python3
"""Pure saturation classifier + throughput reader for the saturation walk."""
import argparse, json, re

def classify(prev_thr, thr, cpu_pct, cores, cpu_frac=0.90, plateau_frac=0.10):
    if cpu_pct >= cpu_frac * cores * 100.0:
        return "cpu"
    if prev_thr > 0 and (thr - prev_thr) / prev_thr < plateau_frac:
        return "plateau"
    return "headroom"

def _last_json_object(text):
    """Extract the last parseable JSON object from coordinator output, which is a
    `mc cp` download log followed by the hdr-merge JSON — the JSON is usually
    PRETTY-PRINTED across multiple lines, so a per-line scan misses it. Mirrors
    render_common.load_merged's strategy."""
    try:
        obj = json.loads(text)
        if isinstance(obj, dict):
            return obj
    except Exception:
        pass
    for o in reversed(re.findall(r"\{.*?\}", text, re.S)):
        try:
            obj = json.loads(o)
            if isinstance(obj, dict):
                return obj
        except Exception:
            continue
    i = text.find("{")
    if i >= 0:
        try:
            obj = json.loads(text[i:])
            if isinstance(obj, dict):
                return obj
        except Exception:
            return None
    return None

def extract_throughput(path):
    """merged.json → aggregate_ops_per_sec or _events_per_sec from its last JSON
    object (multi-line/pretty-printed safe), else 0.0. Missing file → 0.0."""
    try:
        with open(path) as f:
            text = f.read()
    except FileNotFoundError:
        return 0.0
    obj = _last_json_object(text)
    if not isinstance(obj, dict):
        return 0.0
    for k in ("aggregate_ops_per_sec", "aggregate_events_per_sec"):
        if k in obj:
            return float(obj[k])
    return 0.0

def cap_ladder(ladder, stream_count):
    """Cap each ladder rung at the stream_count and dedup (preserving order).

    A rung with more pods than streams would force streams/pod up to 1 and
    over-provision the cell (total streams = pods × ceil(streams/pods) > the
    intended count) — e.g. n=1 at 2 pods drives 2 streams. Capping pods ≤
    stream_count keeps the cell at its labelled cardinality; dedup avoids a
    repeated pod count (which would read as a false 0%-gain plateau)."""
    out = []
    for p in ladder:
        c = min(p, stream_count)
        if c >= 1 and c not in out:
            out.append(c)
    return out

def step_decision(prev_thr, thr, plateau_pct):
    """Decide the walker's next move from consecutive ladder-rung throughputs.

    "error"    -> throughput collapsed to ~0 (choke/thrash); do not pin.
    "continue" -> first rung, or gain still above plateau threshold.
    "plateau"  -> gain at or below plateau threshold; server saturated.
    """
    if thr <= 0:
        return "error"
    if prev_thr <= 0:
        return "continue"
    gain = (thr - prev_thr) / prev_thr
    return "continue" if gain > plateau_pct / 100.0 else "plateau"

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--merged", required=True)
    p.add_argument("--prev-thr", type=float, default=0.0)
    p.add_argument("--cpu", type=float, required=True)
    p.add_argument("--cores", type=float, required=True)
    a = p.parse_args()
    thr = extract_throughput(a.merged)
    print(f"{classify(a.prev_thr, thr, a.cpu, a.cores)} {thr}")

if __name__ == "__main__":
    main()
