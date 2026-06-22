#!/usr/bin/env python3
"""Pure saturation classifier + throughput reader for the calibration bump loop."""
import argparse, json

def classify(prev_thr, thr, cpu_pct, cores, cpu_frac=0.90, plateau_frac=0.10):
    if cpu_pct >= cpu_frac * cores * 100.0:
        return "cpu"
    if prev_thr > 0 and (thr - prev_thr) / prev_thr < plateau_frac:
        return "plateau"
    return "headroom"

def extract_throughput(path):
    """Last JSON object line in merged.json → aggregate_ops_per_sec or _events_per_sec, else 0.0."""
    try:
        with open(path) as f:
            text = f.read()
    except FileNotFoundError:
        return 0.0
    for line in reversed(text.splitlines()):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        for k in ("aggregate_ops_per_sec", "aggregate_events_per_sec"):
            if k in obj:
                return float(obj[k])
        return 0.0
    return 0.0

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
