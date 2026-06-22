#!/usr/bin/env python3
"""render_common.py — shared loaders + metric helpers + formatters for the
phase renderers (render-rawpower.py, render-scaleout.py, render-sustained.py).

Each renderer keeps only its cell-name parsing (dims_*) and its table layout;
everything that reads a rep dir (merged.json / samples.csv / verdict.txt),
aggregates median+cv across repeats, or formats a value lives here so a fix
lands once. Import with:  from render_common import *
"""
import csv, json, math, pathlib, re

CLK_TCK = 100          # assume USER_HZ = 100 (standard Linux)
MiB = 1024 * 1024

__all__ = [
    "CLK_TCK", "MiB",
    "load_merged", "load_samples", "load_verdict", "parse_verdict",
    "cpu_pct_from_samples", "disk_write_mbps_from_samples", "rss_max_mib", "load_rep",
    "_median", "_cv_pct", "aggregate_cell",
    "_dash", "fmt_ops", "fmt_mb", "fmt_mib", "fmt_ms", "fmt_pct", "fmt_cv",
    "verdict_annotation", "ops_with_cv", "cpu_with_cv",
]


# ── file loaders ─────────────────────────────────────────────────────────────

def load_merged(rep_dir: pathlib.Path):
    p = rep_dir / "merged.json"
    if not p.exists():
        return None
    txt = p.read_text()
    # The runner captures the coordinator's full stdout: the `mc cp` download log
    # followed by the hdr-merge JSON. So the file is usually NOT pure JSON —
    # extract the last parseable {...} object.
    try:
        return json.loads(txt)
    except Exception:
        pass
    for o in reversed(re.findall(r"\{.*?\}", txt, re.S)):
        try:
            return json.loads(o)
        except Exception:
            continue
    i = txt.find("{")
    if i >= 0:
        try:
            return json.loads(txt[i:])
        except Exception:
            return None
    return None


def load_samples(rep_dir: pathlib.Path):
    """Return list of (ts_ms, rss_bytes, cpu_ticks, write_bytes) tuples, or None.
    Back-compatible with old 3-column samples.csv (missing write_bytes → 0.0)."""
    p = rep_dir / "samples.csv"
    if not p.exists():
        return None
    try:
        rows = []
        with p.open(newline="") as f:
            for row in csv.DictReader(f):
                rows.append((float(row["ts_ms"]), float(row["rss_bytes"]),
                             float(row["cpu_ticks"]), float(row.get("write_bytes") or 0)))
        return rows if rows else None
    except Exception:
        return None


def parse_verdict(path):
    """Return all key=value lines from a verdict.txt as a dict (str->str)."""
    out = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if "=" in line:
                    k, _, val = line.partition("=")
                    out[k.strip()] = val.strip()
    except (FileNotFoundError, OSError):
        pass
    return out


def load_verdict(rep_dir: pathlib.Path):
    """Return dict of key=value pairs from verdict.txt, or {}."""
    return parse_verdict(rep_dir / "verdict.txt")


# ── metric helpers ───────────────────────────────────────────────────────────

def cpu_pct_from_samples(samples):
    """Mean CPU% from consecutive cpu_ticks deltas / CLK_TCK / elapsed_s. float|None."""
    if not samples or len(samples) < 2:
        return None
    pcts = []
    for i in range(1, len(samples)):
        dt_s = (samples[i][0] - samples[i - 1][0]) / 1000.0
        if dt_s <= 0:
            continue
        dticks = samples[i][2] - samples[i - 1][2]
        if dticks < 0:
            continue  # wrap / reset
        pcts.append(dticks / CLK_TCK / dt_s * 100.0)
    return sum(pcts) / len(pcts) if pcts else None


def rss_max_mib(samples):
    if not samples:
        return None
    return max(s[1] for s in samples) / MiB


def disk_write_mbps_from_samples(samples):
    """Mean disk write MB/s from consecutive write_bytes deltas / elapsed_s. float|None.
    write_bytes = /proc/<pid>/io — the bytes the SERVER actually pushed to the block
    device (ground truth disk throughput, independent of the ops×payload estimate)."""
    if not samples or len(samples) < 2:
        return None
    rates = []
    for i in range(1, len(samples)):
        dt_s = (samples[i][0] - samples[i - 1][0]) / 1000.0
        if dt_s <= 0:
            continue
        dbytes = samples[i][3] - samples[i - 1][3]
        if dbytes < 0:
            continue  # restart / reset
        rates.append(dbytes / 1e6 / dt_s)
    return sum(rates) / len(rates) if rates else None


def load_rep(rep_dir: pathlib.Path):
    """merged.json + samples.csv + verdict.txt for one rep dir. Missing fields → None."""
    m = load_merged(rep_dir)
    samples = load_samples(rep_dir)
    v = load_verdict(rep_dir)

    def mg(key):
        return m.get(key) if m else None

    # fan-out: single-stream emits events_per_sec; multi-fanout aggregate_events_per_sec.
    events_sec = mg("events_per_sec") or mg("aggregate_events_per_sec")
    return {
        "ops":          mg("aggregate_ops_per_sec"),
        "bytes_sec":    mg("bytes_per_sec"),
        "events_sec":   events_sec,
        "p50":          mg("p50_ms"),
        "p99":          mg("p99_ms"),
        "p999":         mg("p999_ms"),
        "merged_count": mg("merged_count"),
        "cpu_pct":      cpu_pct_from_samples(samples),
        "disk_mbps":    disk_write_mbps_from_samples(samples),
        "rss_max_mib":  rss_max_mib(samples),
        "verdict":              v.get("verdict"),
        "collect_error":        mg("error"),   # coordinator marker: e.g. no_client_results_uploaded
        "parallelism":          v.get("parallelism"),
        "cpu_cores":            v.get("server_cpu_cores"),
        "reason":               v.get("reason"),
        "calibration_matched":  v.get("calibration_matched"),
    }


# ── median + cv across reps ──────────────────────────────────────────────────

def _median(vals):
    s = sorted(v for v in vals if v is not None)
    if not s:
        return None
    n = len(s)
    mid = n // 2
    return (s[mid - 1] + s[mid]) / 2 if n % 2 == 0 else s[mid]


def _cv_pct(vals):
    """Coefficient of variation % (sample stddev ÷ N-1 / mean ×100). None for N<2."""
    s = [v for v in vals if v is not None]
    if len(s) < 2:
        return None
    mean = sum(s) / len(s)
    if mean == 0:
        return None
    variance = sum((v - mean) ** 2 for v in s) / (len(s) - 1)
    return math.sqrt(variance) / mean * 100.0


def aggregate_cell(cell_dir: pathlib.Path):
    """Load all rep<N> sub-dirs, aggregate median+cv. Adds 'cv_pct'/'n_reps'.
    'verdict' = worst case (client_capped if any)."""
    rep_dirs = sorted(
        [p for p in cell_dir.iterdir() if p.is_dir() and re.match(r"rep\d+$", p.name)],
        key=lambda p: int(p.name[3:]),
    )
    if not rep_dirs:
        return None

    reps = [load_rep(rd) for rd in rep_dirs]

    def agg(key):
        vals = [r[key] for r in reps]
        return _median(vals), _cv_pct(vals)

    ops_med, ops_cv = agg("ops")
    bytes_med, _    = agg("bytes_sec")
    events_med, _   = agg("events_sec")
    p50_med, _      = agg("p50")
    p99_med, p99_cv = agg("p99")
    p999_med, _     = agg("p999")
    count_med, _    = agg("merged_count")
    cpu_med, cpu_cv = agg("cpu_pct")
    disk_med, _     = agg("disk_mbps")
    rss_med, _      = agg("rss_max_mib")

    # Pessimistic verdict: client_capped or server_headroom (old artifacts) → capped.
    verdicts = [r.get("verdict") for r in reps if r.get("verdict")]
    if any(v in ("client_capped", "server_headroom") for v in verdicts):
        verdict = "client_capped"
    elif "server_bound" in verdicts:
        verdict = "server_bound"
    else:
        verdict = verdicts[0] if verdicts else None

    return {
        "ops": ops_med, "ops_cv": ops_cv,
        "bytes_sec": bytes_med, "events_sec": events_med,
        "p50": p50_med, "p99": p99_med, "p99_cv": p99_cv, "p999": p999_med,
        "merged_count": count_med,
        "cpu_pct": cpu_med, "cpu_cv": cpu_cv, "rss_max_mib": rss_med,
        "disk_mbps": disk_med,
        "verdict": verdict,
        "collect_error": next((r.get("collect_error") for r in reps if r.get("collect_error")), None),
        "parallelism":          reps[-1].get("parallelism"),
        "cpu_cores":            reps[-1].get("cpu_cores"),
        "reason":               reps[-1].get("reason"),
        "calibration_matched":  reps[-1].get("calibration_matched"),
        "n_reps": len(reps),
    }


# ── formatting ───────────────────────────────────────────────────────────────

def _dash(v, fmt=None):
    if v is None:
        return "-"
    return fmt(v) if fmt else str(v)


def fmt_ops(v):
    return f"{v:,.0f}" if v is not None else "-"


def fmt_mb(v):
    """bytes/s → MB/s (or GB/s) string."""
    if v is None:
        return "-"
    mb = v / (1024 * 1024)
    return f"{mb / 1024:.2f} GB/s" if mb >= 1000 else f"{mb:.1f} MB/s"


def fmt_mib(v):
    """A value already in MiB → 1-decimal string."""
    return f"{v:.1f}" if v is not None else "-"


def fmt_ms(v):
    return f"{v:.2f}" if v is not None else "-"


def fmt_pct(v):
    return f"{v:.1f}%" if v is not None else "-"


def fmt_cv(v):
    return f"cv={v:.1f}%" if v is not None else ""


def verdict_annotation(verdict):
    """client_capped and server_headroom are both capped (lower-bound) verdicts."""
    if verdict in ("client_capped", "server_headroom"):
        return "⚠️ client_capped"
    if verdict == "server_bound":
        return "server_bound ✓"
    return verdict or "-"


def ops_with_cv(ops, cv):
    if ops is None:
        return "-"
    s = fmt_ops(ops)
    if cv is not None:
        s += f" ({fmt_cv(cv)})"
    return s


def cpu_with_cv(cpu, cv):
    if cpu is None:
        return "-"
    s = fmt_pct(cpu)
    if cv is not None:
        s += f" ({fmt_cv(cv)})"
    return s
