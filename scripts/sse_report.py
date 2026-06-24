"""Parse a gke-bench.sh summary.tsv into an SSE delivery-latency report:
delivery p99 (ms) per configuration × total-subscribers. SSE is writer-paced, so
the headline metric is delivery p99, not throughput.

Usage: python3 sse_report.py <summary.tsv> [out_basename]
Writes results/<out>.md + results/<out>.csv (default out=sse-comparison)."""
import sys, os, csv, re

# Map gke-bench system:variant -> friendly config label for the final report.
LABEL = {
    ("durable", "walnew"): "wal (cache off)",
    ("durable", "walnew-cache"): "wal (cache on)",
    ("ursula", "memory"): "ursula in-memory",
    ("ursula", "disk"): "ursula disk",
    ("s2", "_"): "s2",
}
ORDER = ["wal (cache off)", "wal (cache on)", "ursula in-memory", "ursula disk", "s2"]


def parse(tsv_paths):
    if isinstance(tsv_paths, str):
        tsv_paths = [tsv_paths]
    rows = []
    seen = set()  # de-dupe (config, subs) across multiple summaries; last wins
    for tsv_path in tsv_paths:
        with open(tsv_path) as f:
            r = csv.DictReader(f, delimiter="\t")
            for row in r:
                if row.get("workload") != "sse":
                    continue
                m = re.search(r"total=(\d+)", row.get("params", ""))
                subs = int(m.group(1)) if m else None
                label = LABEL.get((row["system"], row["variant"]), f'{row["system"]}:{row["variant"]}')
                rec = {"config": label, "subs": subs,
                       "p99_ms": row.get("p99_ms", ""), "evps": row.get("thr_or_evps", "")}
                key = (label, subs)
                if key in seen:
                    rows = [x for x in rows if (x["config"], x["subs"]) != key]
                seen.add(key)
                rows.append(rec)
    return rows


def markdown(rows):
    subs_vals = sorted({r["subs"] for r in rows if r["subs"] is not None})
    configs = [c for c in ORDER if any(r["config"] == c for r in rows)]
    configs += [c for c in sorted({r["config"] for r in rows}) if c not in configs]
    by = {(r["config"], r["subs"]): r for r in rows}
    out = ["# SSE Fan-out — delivery latency (p99 ms)", "",
           "1 stream, 1 writer @ 50 ev/s, swept total subscribers; one well-provisioned",
           "client pod (single wall clock). Metric = delivery **p99 latency** (writer-paced).", ""]
    out += ["| config \\ subscribers | " + " | ".join(str(s) for s in subs_vals) + " |",
            "|" + "---|" * (len(subs_vals) + 1)]
    for c in configs:
        cells = []
        for s in subs_vals:
            r = by.get((c, s))
            cells.append(f'{r["p99_ms"]}' if r and r["p99_ms"] not in ("", "NA") else "—")
        out.append(f"| {c} | " + " | ".join(cells) + " |")
    out += ["", "_p99 in ms; lower is better. — = not measured._", ""]
    return "\n".join(out)


def main():
    # Args: any number of existing .tsv files (summaries, combined) + an optional
    # non-file out basename. Order-independent.
    summaries = [a for a in sys.argv[1:] if os.path.isfile(a)]
    nonfiles = [a for a in sys.argv[1:] if not os.path.isfile(a)]
    out = nonfiles[0] if nonfiles else "sse-comparison"
    if not summaries:
        print("usage: sse_report.py <summary.tsv>... [out_basename]"); sys.exit(2)
    rows = parse(summaries)
    os.makedirs("results", exist_ok=True)
    with open(f"results/{out}.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["config", "subs", "p99_ms", "evps"])
        w.writeheader()
        for r in rows:
            w.writerow(r)
    with open(f"results/{out}.md", "w") as f:
        f.write(markdown(rows))
    print(f"wrote results/{out}.md, results/{out}.csv ({len(rows)} sse rows)")


if __name__ == "__main__":
    main()
