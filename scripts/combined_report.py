"""Combine all write-throughput suites into one cross-configuration report:
the MAX throughput (peak) of every configuration + a stream-count × config matrix
+ per-config saturation walks. Deterministic; reads each suite's per-label
cells.json (already collected locally). No cluster needed.

A "configuration" is a result label: a mode, or a mode×server-config variant
(e.g. wal, wal-tailcache, ursula, s2)."""
import sys, os, glob, json, csv
sys.path.insert(0, os.path.dirname(__file__))
from suite import Suite
import report


def build_combined(suite_paths, results_root="results"):
    all_rows = []
    for sp in suite_paths:
        s = Suite.load(sp)
        rows, _ = report.build(sp, os.path.join(results_root, s.name))
        for r in rows:
            r = dict(r); r["suite"] = s.name
            all_rows.append(r)
    # Peak (max throughput) per configuration label, over cells that produced a number.
    peaks = {}
    for r in all_rows:
        if r.get("status") != "ok":
            continue
        lab = r["mode"]
        if lab not in peaks or r["throughput"] > peaks[lab]["throughput"]:
            peaks[lab] = r
    return all_rows, peaks


def _labels_in_order(all_rows):
    out = []
    for r in all_rows:
        if r["mode"] not in out:
            out.append(r["mode"])
    return out


def _cell(r):
    if r is None:
        return "—"
    if r.get("status") == "error":
        return f"ERR({r['reason']})"
    mark = "" if r.get("saturated") else "†"   # † = not saturated (lower bound)
    return f"{r['throughput']/1000:.0f}k{mark}"


def markdown(all_rows, peaks):
    labels = _labels_in_order(all_rows)
    stream_counts = sorted({r["stream_count"] for r in all_rows})
    out = ["# Write-throughput — max throughput per configuration", ""]

    out += ["## Peak throughput per configuration", ""]
    out += ["| configuration | peak ops/s | at streams | pods | saturated? |",
            "|---|---|---|---|---|"]
    for lab in labels:
        p = peaks.get(lab)
        if p is None:
            out.append(f"| {lab} | — (no successful cell) | — | — | — |")
        else:
            sat = "plateau ✅" if p.get("saturated") else "lower-bound † (ladder exhausted)"
            out.append(f"| {lab} | **{p['throughput']/1000:.0f}k** | {p['stream_count']} | {p['pods']} | {sat} |")
    out += ["", "† = ladder exhausted (still climbing at the last rung) — a lower bound, not the true ceiling.", ""]

    out += ["## Throughput matrix (ops/s)", ""]
    out += ["| streams | " + " | ".join(labels) + " |", "|" + "---|" * (len(labels) + 1)]
    by = {(r["mode"], r["stream_count"]): r for r in all_rows}
    for sc in stream_counts:
        cells = [_cell(by.get((lab, sc))) for lab in labels]
        out.append(f"| {sc} | " + " | ".join(cells) + " |")
    out += [""]

    out += ["## Saturation walks (pods → ops/s)", ""]
    for r in sorted(all_rows, key=lambda r: (r["mode"], r["stream_count"])):
        walk = " → ".join(f"{p}:{t/1000:.0f}k" for p, t in (r.get("walk") or []))
        tag = f"plateau, pinned {r['pods']}" if r.get("saturated") else r.get("reason")
        out.append(f"- **{r['mode']} n={r['stream_count']}**: {walk}  ({tag})")
    out += [""]

    errs = [r for r in all_rows if r.get("status") == "error"]
    out += ["## Errors / caveats", ""]
    if errs:
        for r in errs:
            out.append(f"- **{r['mode']} n={r['stream_count']}**: {r['reason']} (no throughput recorded — not a ceiling).")
    else:
        out.append("- None.")
    out += [""]
    out += ["## Findings", "", "_TODO: narrative on top of the data above._", ""]
    return "\n".join(out)


def main():
    paths = sys.argv[1:] or sorted(glob.glob("suites/write-throughput-*.json"))
    all_rows, peaks = build_combined(paths)
    os.makedirs("results", exist_ok=True)
    with open("results/combined.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["suite", "mode", "stream_count", "pods",
                                          "throughput", "p99", "saturated", "status", "reason"])
        w.writeheader()
        for r in all_rows:
            w.writerow({k: r.get(k) for k in w.fieldnames})
    with open("results/combined-report.md", "w") as f:
        f.write(markdown(all_rows, peaks))
    print("wrote results/combined-report.md, results/combined.csv")
    print("configs:", ", ".join(f"{k}={int(v['throughput'])}" for k, v in peaks.items()))


if __name__ == "__main__":
    main()
