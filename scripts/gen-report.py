#!/usr/bin/env python3
"""gen-report.py <results-dir> [--baseline <variant>] [--out <path>] —
deterministic Markdown report generator for the benchmark suite.

Two result-dir shapes are auto-detected:

  A) Compare runs (scripts/gke-compare-*.sh):
       <dir>/<variant>/<phase>/<run-id>/<cell>/rep<N>/{merged.json,verdict.txt,samples.csv}
     where <phase> ∈ {rawpower, scaleout}. A variant is shape-A if it has a
     rawpower/ or scaleout/ subdir.

  B) Local-card runs (scripts/local-cardinality.sh):
       <dir>/<variant>/<cell>/rep<N>/{merged.json,verdict.txt}
     cells (e.g. ms-n10) sit directly under the variant — no phase/run-id level.

Shared JSON-extraction + headline-selection + aggregation helpers come from
render_common.py (also used by compare-impls.py) so the numbers stay consistent.

Output is deterministic: same input ⇒ byte-identical Markdown. No timestamps,
hostnames, or wall-clock in the body; variants/cells sorted deterministically
(ms-* cells by numeric N); fixed number formatting. Writes to --out, else
<results-dir>/REPORT.md, and prints the path.
"""
import argparse
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import render_common as rc

PHASES = ("rawpower", "scaleout")
# Preferred baselines when --baseline is not given and no obvious default.
BASELINE_PREFS = ("strict", "reference", "wal-strict")


# ── shape detection ──────────────────────────────────────────────────────────

def is_shape_a(variant_dir: pathlib.Path) -> bool:
    """True if the variant has a rawpower/ or scaleout/ phase subdir (shape A)."""
    return any((variant_dir / ph).is_dir() for ph in PHASES)


def list_variants(results_dir: pathlib.Path):
    return sorted(p.name for p in results_dir.iterdir() if p.is_dir())


# ── cell collection ──────────────────────────────────────────────────────────

def cells_for_phase(variant_dir: pathlib.Path, phase: str):
    """Shape A: {cell_name: aggregate_cell(...)} for the latest run-id under phase/."""
    pdir = variant_dir / phase
    if not pdir.is_dir():
        return {}
    runs = sorted(p for p in pdir.iterdir() if p.is_dir())
    if not runs:
        return {}
    run = runs[-1]  # latest run-id (names are <kind>-<ts>-<pid>, lexically sortable)
    out = {}
    for cell in sorted(p for p in run.iterdir() if p.is_dir()):
        a = rc.aggregate_cell(cell)
        if a:
            out[cell.name] = a
    return out


def cells_flat(variant_dir: pathlib.Path):
    """Shape B: {cell_name: aggregate_cell(...)} for cells directly under variant."""
    out = {}
    for cell in sorted(p for p in variant_dir.iterdir() if p.is_dir()):
        a = rc.aggregate_cell(cell)
        if a:
            out[cell.name] = a
    return out


# ── ordering ─────────────────────────────────────────────────────────────────

def cell_sort_key(name: str):
    """Sort ms-*-nN cells by numeric N (n10 < n100 < n1000 < n10000); others
    lexically. Returns (group, numeric, name) so numeric cells stay grouped by
    their non-numeric prefix and tie-break deterministically by full name."""
    m = re.search(r"n(\d+)$", name)
    if m:
        prefix = name[: m.start()]
        return (0, prefix, int(m.group(1)), name)
    return (1, name, 0, name)


def sort_cells(cells):
    return sorted(cells, key=cell_sort_key)


def pick_baseline(variants, requested):
    if requested and requested in variants:
        return requested
    for pref in BASELINE_PREFS:
        if pref in variants:
            return pref
    return variants[0] if variants else None


# ── rate selection / formatting ──────────────────────────────────────────────

def cell_rate(a):
    """(rate, unit) — ops/s for writes/reads, ev/s for fan-out. (None, None) if absent."""
    if a is None:
        return None, None
    ops = a.get("ops")
    if ops is not None:
        return ops, "ops/s"
    ev = a.get("events_sec")
    if ev is not None:
        return ev, "ev/s"
    return None, None


def fmt_cell(a):
    """`rate · p99ms · srvCPU% (par=N)` — '-' where data is missing."""
    if a is None:
        return "-"
    rate, unit = cell_rate(a)
    if rate is None:
        return (a.get("collect_error") or "-")
    p99 = a.get("p99")
    cpu = a.get("cpu_pct")
    par = a.get("parallelism")
    p99_s = f"{p99:.1f}ms" if p99 is not None else "n/a"
    cpu_s = f"{cpu:.1f}%" if cpu is not None else "n/a"
    par_s = par if par is not None else "n/a"
    return f"{rate:,.0f} {unit} · p99 {p99_s} · cpu {cpu_s} (par={par_s})"


def fmt_speedup(num_rate, base_rate):
    if num_rate is None or base_rate is None or base_rate == 0:
        return "-"
    ratio = num_rate / base_rate
    # 1 decimal normally; show 2 for tiny nonzero ratios so they don't read as 0.0×.
    return f"{ratio:.2f}×" if 0 < ratio < 0.1 else f"{ratio:.1f}×"


# ── markdown rendering ───────────────────────────────────────────────────────

def md_table(maps, variants, cell_list):
    """maps: {variant: {cell: agg}}. Returns markdown lines for the data table."""
    lines = [
        "| cell | " + " | ".join(variants) + " |",
        "|" + "---|" * (len(variants) + 1),
    ]
    for cell in cell_list:
        cols = [fmt_cell(maps[v].get(cell)) for v in variants]
        lines.append(f"| {cell} | " + " | ".join(cols) + " |")
    return lines


def md_speedup_table(maps, variants, cell_list, baseline):
    lines = [
        f"Speedup = variant rate ÷ `{baseline}` rate (per cell).",
        "",
        "| cell | " + " | ".join(variants) + " |",
        "|" + "---|" * (len(variants) + 1),
    ]
    for cell in cell_list:
        base_rate, _ = cell_rate(maps[baseline].get(cell))
        cols = []
        for v in variants:
            v_rate, _ = cell_rate(maps[v].get(cell))
            cols.append("1.0×" if v == baseline and v_rate is not None
                        else fmt_speedup(v_rate, base_rate))
        lines.append(f"| {cell} | " + " | ".join(cols) + " |")
    return lines


def parse_cpu_from_name(dir_name: str):
    m = re.search(r"cpu(\d+)", dir_name)
    return m.group(1) if m else None


def render(results_dir: pathlib.Path, baseline_req):
    variants = list_variants(results_dir)
    if not variants:
        return f"# Report — `{results_dir.name}`\n\n_No variant directories found._\n"

    shape_a = any(is_shape_a(results_dir / v) for v in variants)
    baseline = pick_baseline(variants, baseline_req)
    cpu = parse_cpu_from_name(results_dir.name)

    lines = [f"# Benchmark report — `{results_dir.name}`", ""]
    lines.append(f"- Shape: **{'A (compare / multi-phase)' if shape_a else 'B (local-card / flat)'}**")
    lines.append(f"- Variants: " + ", ".join(f"`{v}`" for v in variants))
    lines.append(f"- Baseline: `{baseline}`")
    if cpu:
        lines.append(f"- Server CPU cores (from dir name): {cpu}")

    # Build per-phase (shape A) or flat (shape B) variant→cell maps.
    if shape_a:
        sections = []
        for phase in PHASES:
            maps = {v: cells_for_phase(results_dir / v, phase) for v in variants}
            cell_list = sort_cells(set().union(*[set(m) for m in maps.values()])) if maps else []
            if cell_list:
                sections.append((phase, maps, cell_list))
    else:
        maps = {v: cells_flat(results_dir / v) for v in variants}
        cell_list = sort_cells(set().union(*[set(m) for m in maps.values()])) if maps else []
        sections = [("cells", maps, cell_list)] if cell_list else []

    all_cells = sort_cells(set().union(*[set(cl) for _, _, cl in sections])) if sections else []
    lines.append(f"- Cells: " + (", ".join(f"`{c}`" for c in all_cells) if all_cells else "_none_"))
    lines.append("")
    lines.append("_Cell value = rate · p99 · server CPU% (par = client parallelism). "
                 "Rate is ops/s (writes/reads) or ev/s (fan-out)._")
    lines.append("")

    for title, maps, cell_list in sections:
        lines.append(f"## {title}")
        lines.append("")
        lines += md_table(maps, variants, cell_list)
        lines.append("")
        lines.append(f"### {title} — speedup vs `{baseline}`")
        lines.append("")
        lines += md_speedup_table(maps, variants, cell_list, baseline)
        lines.append("")

    return "\n".join(lines).rstrip("\n") + "\n"


def main():
    ap = argparse.ArgumentParser(description="Deterministic benchmark report generator.")
    ap.add_argument("results_dir", type=pathlib.Path)
    ap.add_argument("--baseline", default=None, help="variant to use as speedup baseline")
    ap.add_argument("--out", type=pathlib.Path, default=None, help="output path (default <dir>/REPORT.md)")
    args = ap.parse_args()

    results_dir = args.results_dir
    if not results_dir.is_dir():
        print(f"error: not a directory: {results_dir}", file=sys.stderr)
        sys.exit(1)

    out = args.out or (results_dir / "REPORT.md")
    text = render(results_dir, args.baseline)
    out.write_text(text)
    print(str(out))


if __name__ == "__main__":
    main()
