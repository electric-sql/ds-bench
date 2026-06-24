"""Aggregate per-mode cells.json into aggregate.csv/json + a markdown skeleton.
Deterministic; no cluster needed."""
import sys, os, json, csv
sys.path.insert(0, os.path.dirname(__file__))
from suite import Suite
import cells as cells_mod


def build(suite_path, results_root):
    s = Suite.load(suite_path)
    rows = []
    for mode in s.modes:
        p = os.path.join(results_root, mode, "cells.json")
        if not os.path.exists(p):
            continue
        for c in cells_mod.all_cells(p):
            rows.append({"mode": mode, "stream_count": c["stream_count"],
                         "pods": c.get("pinned_pods"), "throughput": c.get("throughput"),
                         "p99": c.get("p99"), "saturated": c.get("saturated"),
                         "status": c.get("status"), "reason": c.get("reason"),
                         "walk": c.get("walk")})
    rows.sort(key=lambda r: (r["stream_count"], r["mode"]))
    return rows, _markdown(s, rows)


def _cell_str(r):
    if r["status"] == "error":
        return f"ERROR ({r['reason']})"
    n = r["throughput"]
    mark = "" if r["saturated"] else "†"   # † = not saturated (lower bound)
    return f"{n/1000:.0f}k{mark}"


def _markdown(s, rows):
    out = [f"# {s.name} — write-throughput report", ""]
    out += ["## Throughput at saturation (ops/s)", ""]
    header = "| streams | " + " | ".join(s.modes) + " |"
    out += [header, "|" + "---|" * (len(s.modes) + 1)]
    by = {(r["mode"], r["stream_count"]): r for r in rows}
    for sc in s.stream_counts:
        cells_row = [_cell_str(by[(m, sc)]) if (m, sc) in by else "—" for m in s.modes]
        out.append(f"| {sc} | " + " | ".join(cells_row) + " |")
    out += ["", "† = not saturated (ladder exhausted) — treat as a lower bound.", ""]
    out += ["## Saturation walks (pods → ops/s)", ""]
    for r in rows:
        walk = " → ".join(f"{p}:{t/1000:.0f}k" for p, t in (r["walk"] or []))
        out.append(f"- **{r['mode']} {r['stream_count']}**: {walk}  (pinned {r['pods']}, {r['reason']})")
    out += ["", "## Findings", "", "_TODO: written by hand on top of the generated data._", ""]
    out += ["## Caveats", "", "_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._", ""]
    return "\n".join(out)


def main():
    suite_path = sys.argv[1]
    s = Suite.load(suite_path)
    root = os.path.join("results", s.name)
    rows, md = build(suite_path, root)
    os.makedirs(root, exist_ok=True)
    with open(os.path.join(root, "aggregate.json"), "w") as f:
        json.dump(rows, f, indent=2)
    with open(os.path.join(root, "aggregate.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["mode", "stream_count", "pods", "throughput", "p99", "saturated", "status", "reason"])
        w.writeheader()
        for r in rows:
            w.writerow({k: r[k] for k in w.fieldnames})
    with open(os.path.join(root, "report.md"), "w") as f:
        f.write(md)
    print(f"wrote {root}/aggregate.csv, aggregate.json, report.md")


if __name__ == "__main__":
    main()
