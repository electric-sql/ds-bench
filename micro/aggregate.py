#!/usr/bin/env python3
"""Aggregate autobench results.jsonl -> RESULTS.md (median +/- variance per cell).

Groups rows by (study, scenario, <all dimension fields>) and reports the median
of each metric across repeats, plus the coefficient of variation of throughput
(rps) so noisy cells are visible.
"""
import json
import sys
import statistics as st
from collections import defaultdict

METRICS = ["rps", "mbps", "p50_ms", "p99_ms", "max_ms", "cpu_pct"]
SKIP_DIMS = {"rep"}

def load(path):
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return rows

def med(xs):
    xs = [x for x in xs if isinstance(x, (int, float))]
    return st.median(xs) if xs else None

def cv(xs):
    xs = [x for x in xs if isinstance(x, (int, float)) and x == x]
    if len(xs) < 2:
        return 0.0
    m = st.mean(xs)
    return (st.pstdev(xs) / m * 100) if m else 0.0

def fmt(v):
    if v is None:
        return ""
    if isinstance(v, float):
        if v >= 1000:
            return f"{v:,.0f}"
        if v >= 100:
            return f"{v:.0f}"
        return f"{v:.2f}"
    return str(v)

def main():
    rows = load(sys.argv[1])
    meta = open(sys.argv[2]).read() if len(sys.argv) > 2 else ""

    print("# autobench results\n")
    if meta:
        print("```")
        print(meta.strip())
        print("```\n")
    if not rows:
        print("_no results_")
        return
    print(f"Total cells: {len(rows)} rows. Throughput is median across repeats; "
          "**rps cv%** is the coefficient of variation (run-to-run noise).\n")

    # group by study -> scenario -> dimension-tuple
    studies = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))
    for r in rows:
        study = r.get("study", "?")
        scen = r.get("scenario", "?")
        dims = tuple(sorted(
            (k, r[k]) for k in r
            if k not in METRICS and k not in SKIP_DIMS and k not in ("study", "scenario")
        ))
        studies[study][scen][dims].append(r)

    for study in sorted(studies):
        print(f"## {study}\n")
        for scen in sorted(studies[study]):
            groups = studies[study][scen]
            # dimension columns present in this scenario
            dim_keys = []
            for dims in groups:
                for k, _ in dims:
                    if k not in dim_keys:
                        dim_keys.append(k)
            # which metrics actually appear
            present = [m for m in METRICS if any(m in r for g in groups.values() for r in g)]
            hdr = dim_keys + ["n"] + [m for m in present] + (["rps_cv%"] if "rps" in present else [])
            print(f"### {scen}\n")
            print("| " + " | ".join(hdr) + " |")
            print("|" + "|".join(["---"] * len(hdr)) + "|")
            # sort rows by dimension values (numeric-aware)
            def sortkey(item):
                d = dict(item[0])
                out = []
                for k in dim_keys:
                    v = d.get(k, "")
                    try:
                        out.append((0, float(v)))
                    except (TypeError, ValueError):
                        out.append((1, str(v)))
                return out
            for dims, rs in sorted(groups.items(), key=sortkey):
                d = dict(dims)
                line = [fmt(d.get(k, "")) for k in dim_keys]
                line.append(str(len(rs)))
                for m in present:
                    line.append(fmt(med([r.get(m) for r in rs])))
                if "rps" in present:
                    line.append(f"{cv([r.get('rps') for r in rs]):.1f}")
                print("| " + " | ".join(line) + " |")
            print()

if __name__ == "__main__":
    main()
