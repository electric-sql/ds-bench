#!/usr/bin/env python3
"""compare-impls.py <compare-dir> — side-by-side comparison of server implementations.

Layout expected:
    <compare-dir>/<impl>/<phase>/<run-id>/<cell>/rep<n>/{merged.json,samples.csv,verdict.txt}
where <phase> ∈ {rawpower, scaleout}. Each impl dir is auto-detected (must contain a
rawpower/ or scaleout/ subdir). Writes <compare-dir>/COMPARISON.md and prints it.
"""
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import render_common as rc

PHASES = ("rawpower", "scaleout")


def impl_cells(impl_dir: pathlib.Path, phase: str):
    """{cell_name: aggregate_cell(...)} for the single run-id under impl_dir/phase/."""
    pdir = impl_dir / phase
    if not pdir.is_dir():
        return {}
    runs = sorted(p for p in pdir.iterdir() if p.is_dir())
    if not runs:
        return {}
    run = runs[-1]
    out = {}
    for cell in sorted(p for p in run.iterdir() if p.is_dir()):
        a = rc.aggregate_cell(cell)
        if a:
            out[cell.name] = a
    return out


def rate(a):
    r = a.get("ops") or a.get("events_sec") or 0
    u = "ev/s" if (a.get("events_sec") and not a.get("ops")) else "op/s"
    return r, u


def main():
    if len(sys.argv) < 2:
        print("usage: compare-impls.py <compare-dir>"); return
    cdir = pathlib.Path(sys.argv[1])
    impls = sorted(p.name for p in cdir.iterdir()
                   if p.is_dir() and any((p / ph).is_dir() for ph in PHASES))
    if len(impls) < 2:
        print(f"need ≥2 implementations under {cdir}, found {impls}"); return

    lines = [f"# Implementation comparison — `{cdir.name}`", "",
             "Implementations: " + ", ".join(f"`{i}`" for i in impls),
             "", "_rate = ops/s (writes/reads) or ev/s (fan-out). Winner = highest rate; "
             "ratio vs runner-up. par = client pods (headroom-bumped per server)._", ""]

    for phase in PHASES:
        maps = {i: impl_cells(cdir / i, phase) for i in impls}
        cells = sorted(set().union(*[set(m) for m in maps.values()])) if maps else []
        if not cells:
            continue
        lines += [f"## {phase}", "",
                  "| cell | " + " | ".join(impls) + " | winner |",
                  "|" + "---|" * (len(impls) + 2)]
        for cell in cells:
            cols, rates = [], {}
            for i in impls:
                a = maps[i].get(cell)
                if not a or (a.get("ops") is None and a.get("events_sec") is None):
                    cols.append((a or {}).get("collect_error") or "–")
                    rates[i] = None
                    continue
                r, u = rate(a)
                rates[i] = r
                cols.append(f"{r:,.0f} {u} · p99 {a.get('p99') or 0:.0f}ms · par={a.get('parallelism')}")
            valid = {i: v for i, v in rates.items() if v}
            if len(valid) >= 2:
                ranked = sorted(valid.items(), key=lambda kv: kv[1], reverse=True)
                ratio = ranked[0][1] / ranked[1][1] if ranked[1][1] else 0
                win = f"**{ranked[0][0]}** {ratio:.1f}×"
            elif len(valid) == 1:
                win = f"**{next(iter(valid))}** (only)"
            else:
                win = "–"
            lines.append(f"| {cell} | " + " | ".join(cols) + f" | {win} |")
        lines.append("")

    out = "\n".join(lines)
    print(out)
    (cdir / "COMPARISON.md").write_text(out)
    print(f"\n→ wrote {cdir / 'COMPARISON.md'}")


main()
