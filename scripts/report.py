"""Aggregate per-mode cells.json into aggregate.csv/json + a markdown skeleton.
Deterministic; no cluster needed."""
import sys, os, json, csv
sys.path.insert(0, os.path.dirname(__file__))
from suite import Suite
import cells as cells_mod


def build(suite_path, results_root):
    s = Suite.load(suite_path)
    rows = []
    # One result series per LABEL (mode × server-config variant) — variants like
    # wal vs wal-tailcache land in adjacent columns. `mode` field holds the label.
    for label in s.labels():
        p = os.path.join(results_root, label, "cells.json")
        if not os.path.exists(p):
            continue
        for c in cells_mod.all_cells(p):
            rows.append({"mode": label, "stream_count": c["stream_count"],
                         "pods": c.get("pinned_pods"), "throughput": c.get("throughput"),
                         "p50": c.get("p50"), "p99": c.get("p99"), "pod_mem_mb": c.get("pod_mem_mb"),
                         "saturated": c.get("saturated"),
                         "status": c.get("status"), "reason": c.get("reason"),
                         "walk": c.get("walk")})
    rows.sort(key=lambda r: (r["stream_count"], r["mode"]))
    return rows, _markdown(s, rows)


def suite_status(suite_path, results_root):
    """Overall completion state of a suite's run, for auto-teardown decisions:
      "complete"   — every (label × stream_count) cell present and status "ok".
      "errors"     — all cells present but at least one status "error" (keep the
                     cluster for investigation / resume).
      "incomplete" — a cell is missing (run didn't finish; keep the cluster)."""
    s = Suite.load(suite_path)
    saw_error = False
    for label in s.labels():
        p = os.path.join(results_root, label, "cells.json")
        by_sc = {c["stream_count"]: c for c in cells_mod.all_cells(p)} if os.path.exists(p) else {}
        for sc in s.stream_counts:
            c = by_sc.get(sc)
            if c is None:
                return "incomplete"
            if c.get("status") == "error":
                saw_error = True
    return "errors" if saw_error else "complete"


def _cell_str(r):
    if r["status"] == "error":
        return f"ERROR ({r['reason']})"
    n = r["throughput"]
    mark = "" if r["saturated"] else "†"   # † = not saturated (lower bound)
    return f"{n/1000:.0f}k{mark}"


def _markdown(s, rows):
    labels = s.labels()
    out = [f"# {s.name} — write-throughput report", ""]
    out += ["## Throughput at saturation (ops/s)", ""]
    header = "| streams | " + " | ".join(labels) + " |"
    out += [header, "|" + "---|" * (len(labels) + 1)]
    by = {(r["mode"], r["stream_count"]): r for r in rows}
    for sc in s.stream_counts:
        cells_row = [_cell_str(by[(m, sc)]) if (m, sc) in by else "—" for m in labels]
        out.append(f"| {sc} | " + " | ".join(cells_row) + " |")
    out += ["", "† = not saturated (ladder exhausted) — treat as a lower bound.", ""]

    # Peak pod working-set memory (anon + active page cache) at saturation. Uniform
    # across implementations, so it captures a resident cache (shows as memory) vs an
    # OS-paging design (data in page cache, also charged to the pod) on equal terms.
    if any(r.get("pod_mem_mb") for r in rows):
        out += ["## Peak pod memory at saturation (MiB)", ""]
        out += [header, "|" + "---|" * (len(labels) + 1)]
        for sc in s.stream_counts:
            mrow = []
            for m in labels:
                r = by.get((m, sc))
                mrow.append(f"{r['pod_mem_mb']:.0f}" if r and r.get("pod_mem_mb") else "—")
            out.append(f"| {sc} | " + " | ".join(mrow) + " |")
        out += ["", "_Pod working set = cgroup `memory.current − inactive_file`; counts the "
                "server's resident memory **and** the page cache it keeps hot._", ""]

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
        w = csv.DictWriter(f, fieldnames=["mode", "stream_count", "pods", "throughput", "p50", "p99", "pod_mem_mb", "saturated", "status", "reason"])
        w.writeheader()
        for r in rows:
            w.writerow({k: r[k] for k in w.fieldnames})
    with open(os.path.join(root, "report.md"), "w") as f:
        f.write(md)
    print(f"wrote {root}/aggregate.csv, aggregate.json, report.md")


if __name__ == "__main__":
    main()
