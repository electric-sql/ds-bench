# Sustained workload in gke-bench + server-memory columns — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fold the existing `sustained` benchmark into the unified `scripts/gke-bench.sh` matrix as a default workload, and add two server-memory columns (peak / drift) derived from the RSS the sidecar already samples.

**Architecture:** Three localized changes — a new awk helper in `scripts/lib-bench.sh` (mirrors `compute_server_cpu_pct`), two new columns wired into `gke-bench.sh`'s `run_one` + summary header, and a new `sustained` matrix branch (durable-only) with its own knobs. No changes to the Rust `ds-bench` binary.

**Tech Stack:** Bash, awk, kind (local kubernetes), the existing `ds-bench` `sustained` subcommand.

## Global Constraints

- Development/validation is **local only** (`DS_TARGET=local` on kind); no remote GKE runs.
- Sustained is **durable-only**: `supports()` returns false for `sustained` on `ursula`/`s2`.
- Memory columns are sidecar-instrumented for durable only; `ursula`/`s2` report `0` (like `cpu_pct`).
- Defaults (verbatim): `SUSTAINED_CARDS="10 50 100 150"`, `SUSTAINED_RATE=10`, `SUSTAINED_DURATION=90`.
- `samples.csv` header is `ts_ms,rss_bytes,cpu_ticks,write_bytes` — RSS is column 2.
- Summary header today: `system variant workload params pods rep thr_or_evps p99_ms cpu_pct` (tab-separated).
- Follow existing bash conventions in `scripts/lib-bench.sh` and `scripts/gke-bench.sh`.

---

### Task 1: `compute_server_mem_mb` helper + cluster-free test

**Files:**
- Modify: `scripts/lib-bench.sh` (add helper immediately after `compute_server_cpu_pct`, ~line 235)
- Create: `scripts/lib-bench_mem_test.sh`

**Interfaces:**
- Produces: `compute_server_mem_mb SAMPLES_CSV` — prints one line `"PEAK_MB DRIFT_MB"` (two space-separated integers). `peak = max(rss_bytes)/MiB`; `drift = (rss_last - rss_first)/MiB` (may be negative). Prints `"0 0"` when the CSV has no data rows.

- [ ] **Step 1: Write the failing test**

Create `scripts/lib-bench_mem_test.sh`:

```bash
#!/usr/bin/env bash
# lib-bench_mem_test.sh — cluster-free unit test for compute_server_mem_mb.
# Exit 0 = PASS, non-zero = FAIL.
set -uo pipefail

export DS_TARGET=local
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export REPO_ROOT
# shellcheck source=scripts/lib-bench.sh
source "${REPO_ROOT}/scripts/lib-bench.sh"

tmp="$(mktemp -d /tmp/lib-bench-mem-XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
PASS=true

check() {  # name csv_content expected
  local name="$1" csv="$2" expected="$3" got
  printf '%s' "$csv" > "${tmp}/s.csv"
  got="$(compute_server_mem_mb "${tmp}/s.csv")"
  if [ "$got" != "$expected" ]; then
    echo "FAIL [$name]: expected '$expected', got '$got'"; PASS=false
  else
    echo "ok [$name]: $got"
  fi
}

# 1 MiB = 1048576 bytes. start=100MiB, peak=300MiB, end=250MiB -> peak=300 drift=150
check growth \
  $'ts_ms,rss_bytes,cpu_ticks,write_bytes\n1000,104857600,0,0\n2000,314572800,0,0\n3000,262144000,0,0\n' \
  "300 150"

# settles back below start: start=300MiB end=200MiB peak=300MiB -> peak=300 drift=-100
check negative_drift \
  $'ts_ms,rss_bytes,cpu_ticks,write_bytes\n1000,314572800,0,0\n2000,209715200,0,0\n' \
  "300 -100"

# header only, no data rows -> "0 0"
check empty \
  $'ts_ms,rss_bytes,cpu_ticks,write_bytes\n' \
  "0 0"

$PASS && { echo "PASS"; exit 0; } || { echo "FAILED"; exit 1; }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/lib-bench_mem_test.sh`
Expected: FAIL — `compute_server_mem_mb` is undefined, so `got` is empty and all three `check` lines FAIL (non-zero exit).

- [ ] **Step 3: Add the helper**

In `scripts/lib-bench.sh`, immediately after the closing `}` of `compute_server_cpu_pct` (around line 235), add:

```bash
# compute_server_mem_mb SAMPLES_CSV — prints "PEAK_MB DRIFT_MB" from rss_bytes (col 2).
#   peak  = max(rss)               (high-water mark, MiB)
#   drift = rss(last) - rss(first) (growth over the window, MiB; may be negative)
# Sidecar-instrumented for durable only; "0 0" when there are no data rows.
compute_server_mem_mb() {
  awk -F',' '
    NR==1 { next }
    NR==2 { r0=$2; rl=$2; peak=$2; next }
    { rl=$2; if ($2>peak) peak=$2 }
    END {
      if (r0=="") { print "0 0"; exit }
      printf "%.0f %.0f\n", peak/1048576, (rl - r0)/1048576
    }' "$1"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/lib-bench_mem_test.sh`
Expected: PASS — three `ok` lines (`300 150`, `300 -100`, `0 0`) then `PASS`, exit 0.

- [ ] **Step 5: Lint**

Run: `bash -n scripts/lib-bench.sh && bash -n scripts/lib-bench_mem_test.sh`
Expected: no output, exit 0.

- [ ] **Step 6: Commit**

```bash
chmod +x scripts/lib-bench_mem_test.sh
git add scripts/lib-bench.sh scripts/lib-bench_mem_test.sh
git commit -m "bench: add compute_server_mem_mb helper (peak/drift from rss samples)"
```

---

### Task 2: Wire `mem_peak_mb` / `mem_drift_mb` columns into gke-bench summary

**Files:**
- Modify: `scripts/gke-bench.sh` (summary header line ~89; `run_one` body ~143-147; KNOWN LIMITATION comment ~30-32)

**Interfaces:**
- Consumes: `compute_server_mem_mb` (Task 1).
- Produces: every `summary.tsv` row gains two trailing fields `mem_peak_mb` and `mem_drift_mb` after `cpu_pct`.

- [ ] **Step 1: Extend the summary header**

In `scripts/gke-bench.sh`, replace the header printf (line ~89):

```bash
printf 'system\tvariant\tworkload\tparams\tpods\trep\tthr_or_evps\tp99_ms\tcpu_pct\n' > "$SUM"
```

with:

```bash
printf 'system\tvariant\tworkload\tparams\tpods\trep\tthr_or_evps\tp99_ms\tcpu_pct\tmem_peak_mb\tmem_drift_mb\n' > "$SUM"
```

- [ ] **Step 2: Compute + emit memory in `run_one`**

In `run_one`, the rep loop currently does (lines ~142-147):

```bash
    cd="$RESULTS_ROOT/$rcell/rep1"
    cpu="$(compute_server_cpu_pct "$cd/samples.csv" 2>/dev/null || echo 0)"
    thr="$(python3 scripts/saturation.py --merged "$cd/merged.json" --prev-thr 0 --cpu "$cpu" --cores 1 2>/dev/null | awk '{print $2}')"
    p99="$(grep -oE '"p99_ms"[: ]*[0-9.]+' "$cd/merged.json" 2>/dev/null | grep -oE '[0-9.]+$' | head -1)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$sys" "$var" "$wl" "$params" "$pods" "$rep" "${thr:-0}" "${p99:-NA}" "${cpu:-0}" | tee -a "$SUM"
```

Replace that block with (add `mem_peak`/`mem_drift` to the locals declared at the top of `run_one` too — change `local rep cd thr p99 cpu cmd` to `local rep cd thr p99 cpu cmd mem_peak mem_drift`):

```bash
    cd="$RESULTS_ROOT/$rcell/rep1"
    cpu="$(compute_server_cpu_pct "$cd/samples.csv" 2>/dev/null || echo 0)"
    read -r mem_peak mem_drift < <(compute_server_mem_mb "$cd/samples.csv" 2>/dev/null || echo "0 0")
    thr="$(python3 scripts/saturation.py --merged "$cd/merged.json" --prev-thr 0 --cpu "$cpu" --cores 1 2>/dev/null | awk '{print $2}')"
    p99="$(grep -oE '"p99_ms"[: ]*[0-9.]+' "$cd/merged.json" 2>/dev/null | grep -oE '[0-9.]+$' | head -1)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$sys" "$var" "$wl" "$params" "$pods" "$rep" "${thr:-0}" "${p99:-NA}" "${cpu:-0}" "${mem_peak:-0}" "${mem_drift:-0}" | tee -a "$SUM"
```

- [ ] **Step 3: Extend the KNOWN LIMITATION comment**

In the header comment (lines ~30-32), replace:

```bash
# KNOWN LIMITATION: the cpu_pct column (server CPU%, from a metrics sidecar) is
# instrumented for durable-streams ONLY. Ursula and S2 are not instrumented and
# report cpu_pct=0 — by design; we don't read their server CPU.
```

with:

```bash
# KNOWN LIMITATION: the cpu_pct AND mem_peak_mb/mem_drift_mb columns (server CPU%
# and RSS, from a metrics sidecar) are instrumented for durable-streams ONLY.
# Ursula and S2 are not instrumented and report 0 — by design; we don't read
# their server CPU/memory.
```

- [ ] **Step 4: Lint + header-count check**

Run:
```bash
bash -n scripts/gke-bench.sh && \
TS=0 RESULTS_ROOT="$(mktemp -d)" && \
printf 'system\tvariant\tworkload\tparams\tpods\trep\tthr_or_evps\tp99_ms\tcpu_pct\tmem_peak_mb\tmem_drift_mb\n' | awk -F'\t' '{print NF}'
```
Expected: `bash -n` prints nothing (exit 0); the awk prints `11` (the row printf must emit the same 11 fields — verify by eye that the `printf` in Step 2 has eleven `%s` and eleven args).

- [ ] **Step 5: Commit**

```bash
git add scripts/gke-bench.sh
git commit -m "bench: add mem_peak_mb/mem_drift_mb columns to gke-bench summary"
```

---

### Task 3: Add the `sustained` matrix branch (durable-only) + knobs + docs

**Files:**
- Modify: `scripts/gke-bench.sh` (default `WORKLOADS` ~59; new knobs ~73; `supports()` ~128; matrix branch ~159-184; header comment WORKLOADS list ~11-13)
- Modify: `BENCHMARKING.md` (stale `scripts/gke-sustained.sh` references)

**Interfaces:**
- Consumes: `run_one`, `clamp_pods`, `deploy_system` placeholders `__T__`/`__A__`/`__NS__` (all existing).
- Produces: matrix cells `${sys}-${var}-sustained-n${n}` for `durable` systems only.

- [ ] **Step 1: Add `sustained` to the default workload set**

In `scripts/gke-bench.sh`, replace (line ~59):

```bash
WORKLOADS="${WORKLOADS:-write sse replay}"
```

with:

```bash
WORKLOADS="${WORKLOADS:-write sse replay sustained}"
```

- [ ] **Step 2: Add the sustained knobs**

After the `REPLAY_CONF=...` line (~73), add:

```bash
# Sustained: steady low per-stream rate over a LONG window (RSS drift / latency
# stability over time), swept over stream counts. Durable-only (memory is the point,
# and only durable is sidecar-instrumented). Its own long DURATION, separate from
# the short write/sse window above.
SUSTAINED_CARDS="${SUSTAINED_CARDS:-10 50 100 150}"   # stream counts
SUSTAINED_RATE="${SUSTAINED_RATE:-10}"                # per-stream ops/sec
SUSTAINED_DURATION="${SUSTAINED_DURATION:-90}"        # long, so the RSS sidecar captures drift
```

- [ ] **Step 3: Make `supports()` skip sustained on non-durable**

Replace `supports()` (line ~128):

```bash
supports() { local sys="$1" wl="$2"; [ "$sys" = s2 ] && [ "$wl" = replay ] && return 1; return 0; }
```

with:

```bash
supports() {
  local sys="$1" wl="$2"
  [ "$sys" = s2 ] && [ "$wl" = replay ] && return 1
  # sustained measures server MEMORY stability — only durable is sidecar-instrumented.
  [ "$wl" = sustained ] && [ "$sys" != durable ] && return 1
  return 0
}
```

- [ ] **Step 4: Add the sustained matrix branch**

In the `case "$wl" in` block, after the `replay)` branch ends (its `;;` ~line 183, before the closing `esac`), add:

```bash
      sustained)
        for n in $SUSTAINED_CARDS; do
          pods="$(clamp_pods "$n")"; perpod=$(( (n + pods - 1) / pods ))
          run_one "$sys" "$var" sustained "n=$n,rate=$SUSTAINED_RATE" "$pods" "${sys}-${var}-sustained-n${n}" \
            "sustained --target __T__ --api-style __A__ __NS__ --streams ${perpod} --rate-per-stream ${SUSTAINED_RATE} --duration-secs ${SUSTAINED_DURATION} --snapshot-secs 5 --setup-concurrency 256" \
            "ds-bench hdr-merge --hdr-dir /merge --results-dir /merge --label-prefix sustained-"
        done ;;
```

- [ ] **Step 5: Update the WORKLOADS line in the header comment**

In the header comment (lines ~11-13), replace:

```bash
#   WORKLOADS  write   — multi-stream append throughput (ops/s + p99)
#              sse     — single-/multi-stream fan-out delivery latency (p99)
#              replay  — catch-up / mass reconnect (p99 + snapshot bytes)
```

with:

```bash
#   WORKLOADS  write     — multi-stream append throughput (ops/s + p99)
#              sse       — single-/multi-stream fan-out delivery latency (p99)
#              replay    — catch-up / mass reconnect (p99 + snapshot bytes)
#              sustained — steady low rate over a LONG window → server RSS drift /
#                          latency stability over time (durable-only)
```

- [ ] **Step 6: Update BENCHMARKING.md**

In `BENCHMARKING.md`, the Phase-3 section references `scripts/gke-sustained.sh` (lines ~21, ~96-98). Replace those invocation lines so the sustained phase points at the unified runner. Change the table row (line ~21):

```
| **3 — sustained** | `scripts/gke-sustained.sh` | steady load over time → server **RSS drift / memory stability** + throughput/p99 vs stream count |
```

to:

```
| **3 — sustained** | `WORKLOADS=sustained scripts/gke-bench.sh` | steady load over time → server **RSS drift / memory stability** (mem_peak_mb/mem_drift_mb) + throughput/p99 vs stream count; durable-only |
```

and replace the example block (lines ~96-98):

```
# Phase 3 — sustained (system = durable; ursula/s2 are remote-only comparisons)
scripts/gke-sustained.sh durable sustained          # default stream sweep 10 50 100 150
scripts/gke-sustained.sh durable sustained 10 100   # custom stream counts
```

with:

```
# Phase 3 — sustained is now a workload in the unified runner (durable-only).
WORKLOADS=sustained SYSTEMS=durable:strict scripts/gke-bench.sh        # default sweep 10 50 100 150
WORKLOADS=sustained SUSTAINED_CARDS="10 100" scripts/gke-bench.sh      # custom stream counts
# (the standalone scripts/legacy/gke-sustained.sh is retained as a legacy reference)
```

- [ ] **Step 7: Lint + static assertions**

Run:
```bash
bash -n scripts/gke-bench.sh && \
grep -q 'write sse replay sustained' scripts/gke-bench.sh && \
grep -q 'sustained --target __T__' scripts/gke-bench.sh && \
grep -q 'wl. = sustained .. .. .sys. != durable' scripts/gke-bench.sh && \
echo "STATIC OK"
```
Expected: `STATIC OK` (exit 0). `bash -n` emits nothing.

- [ ] **Step 8: Commit**

```bash
git add scripts/gke-bench.sh BENCHMARKING.md
git commit -m "bench: fold sustained workload into gke-bench matrix (durable-only)"
```

---

### Task 4: Local integration validation (kind)

**Files:** none (validation only).

This is the real end-to-end check; per the Global Constraints it runs **locally only**. Requires a local kind cluster. If no cluster is currently up, the executing agent should NOT attempt remote — instead report that Steps 1-4 below are the manual gate for the user to run on their kind cluster.

- [ ] **Step 1: Bring up local kind + durable image (skip if already running)**

Run: `scripts/cluster-up.sh` then `scripts/build-images.sh` (or the project's documented local image-load step).
Expected: cluster Ready; durable-streams image loadable.

- [ ] **Step 2: Smoke-run the sustained workload (tiny params, local)**

Run:
```bash
DS_TARGET=local SYSTEMS=durable:strict WORKLOADS=sustained \
  SUSTAINED_CARDS=10 SUSTAINED_DURATION=20 REPEATS=1 \
  scripts/gke-bench.sh
```
Expected: a `durable-strict-sustained-n10` cell runs to completion; final `summary.tsv` printed.

- [ ] **Step 3: Assert sustained row + populated memory columns**

Run:
```bash
SUM="$(ls -t results/bench/bench-*/summary.tsv | head -1)"
head -1 "$SUM" | grep -q 'mem_peak_mb' && echo "HEADER OK"
awk -F'\t' '$3=="sustained" && $10+0>0 {print "ROW OK:", $0}' "$SUM"
```
Expected: `HEADER OK` and a `ROW OK:` line where `mem_peak_mb` (field 10) is non-zero. Confirm `results/bench/bench-*/durable-strict-sustained-n10-r1/rep1/samples.csv` exists.

- [ ] **Step 4: Regression — write still works with new columns**

Run:
```bash
DS_TARGET=local SYSTEMS=durable:strict WORKLOADS=write \
  WRITE_CARDS=1000 REPEATS=1 scripts/gke-bench.sh
SUM="$(ls -t results/bench/bench-*/summary.tsv | head -1)"
awk -F'\t' 'NR==1{print NF" cols"} $3=="write"{print "WRITE ROW:", NF" fields"}' "$SUM"
```
Expected: header `11 cols` and the write row also `11 fields` (no schema drift; mem columns present, may be `0` or non-zero).

- [ ] **Step 5: No commit** (validation only). Record results in the PR/branch notes.

---

## Self-Review

- **Spec coverage:** §1 sustained cell → Task 3; §1 knobs/defaults → Task 3 Step 2; §1 supports() durable-only → Task 3 Step 3; §2 helper → Task 1; §2 columns + KNOWN LIMITATION → Task 2; §3 docs → Task 3 Steps 5-6; §Validation → Task 4. All covered.
- **Placeholder scan:** none — every code/command step has literal content.
- **Type consistency:** `compute_server_mem_mb` prints `"PEAK_MB DRIFT_MB"` (Task 1) and is consumed via `read -r mem_peak mem_drift` (Task 2). Column order `cpu_pct, mem_peak_mb, mem_drift_mb` consistent across header (Task 2 Step 1), row printf (Task 2 Step 2), and validation field indices (`$10` = mem_peak_mb; Task 4 Step 3). Eleven fields throughout.
