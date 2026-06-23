# Sustained workload in the gke-bench matrix + server-memory tracking

**Date:** 2026-06-23
**Branch:** `vbalegas/sustained-in-gke-bench`
**Status:** approved design

## Goal

Fold the existing `sustained` benchmark (steady-rate, long-duration load — already
implemented as the `sustained` subcommand in `ds-bench` and previously driven only by
the standalone `scripts/legacy/gke-sustained.sh`) into the unified matrix runner
`scripts/gke-bench.sh`, as a first-class workload that runs in the **default**
`WORKLOADS` set. Alongside it, add **server-memory tracking** to the matrix output —
two derived columns computed from the RSS the metrics sidecar already samples, exactly
parallel to how `cpu_pct` is derived from CPU ticks.

All development/validation in this branch is **local only** (`DS_TARGET=local` on kind);
no remote GKE runs.

## Background (current state)

- `gke-bench.sh` runs a matrix `SYSTEMS × WORKLOADS`. Default
  `WORKLOADS="write sse replay"`. Each cell = clean server deploy + (warmup/settle for
  write/sse) + `REPEATS` reps → one row in `results/bench/bench-<ts>/summary.tsv` with
  columns `system variant workload params pods rep thr_or_evps p99_ms cpu_pct`.
- The row is written directly by `run_one` in `gke-bench.sh`. No separate Python renderer
  parses `summary.tsv` (it is printed via `column -t`), so adding columns there is
  self-contained.
- The metrics sidecar already writes `samples.csv` per cell with header
  `ts_ms,rss_bytes,cpu_ticks,write_bytes`. `run_cell` calls `reset_sidecar_samples`
  before and `collect_sidecar` after, and `collect_sidecar` works on local kind.
- `compute_server_cpu_pct` (in `lib-bench.sh`) already derives `cpu_pct` from column 3
  (`cpu_ticks`). The sidecar is instrumented for **durable only**; `ursula`/`s2` report
  `cpu_pct=0` by design (documented KNOWN LIMITATION).
- The `sustained` subcommand (`ds-bench/src/sustained.rs`) drives each stream at exactly
  `--rate-per-stream` ops/sec via a `tokio::time::interval` over `--duration-secs`,
  prints a latency snapshot series, and emits a mergeable HDR file + JSON summary with
  `aggregate_ops_per_sec` and a latency `p99`.

## Changes

### 1. New `sustained` workload cell (`gke-bench.sh`)

- Add `sustained` to the default workload set: `WORKLOADS="write sse replay sustained"`.
- New knobs (overridable; defaults taken from the proven legacy script):
  - `SUSTAINED_CARDS="${SUSTAINED_CARDS:-10 50 100 150}"` — stream-count sweep.
  - `SUSTAINED_RATE="${SUSTAINED_RATE:-10}"` — per-stream offered load (ops/sec).
  - `SUSTAINED_DURATION="${SUSTAINED_DURATION:-90}"` — long window (separate from the
    20s `DURATION` used by write/sse) so the RSS sidecar captures drift.
- New branch in the `for wl` loop (mirrors the `write` branch: pod split via
  `clamp_pods`, fleet aggregates to `n` total streams):

  ```sh
  sustained)
    for n in $SUSTAINED_CARDS; do
      pods="$(clamp_pods "$n")"; perpod=$(( (n + pods - 1) / pods ))
      run_one "$sys" "$var" sustained "n=$n,rate=$SUSTAINED_RATE" "$pods" "${sys}-${var}-sustained-n${n}" \
        "sustained --target __T__ --api-style __A__ __NS__ --streams ${perpod} --rate-per-stream ${SUSTAINED_RATE} --duration-secs ${SUSTAINED_DURATION} --snapshot-secs 5 --setup-concurrency 256" \
        "ds-bench hdr-merge --hdr-dir /merge --results-dir /merge --label-prefix sustained-"
    done ;;
  ```

- No warmup/settle flags (unlike write/sse) — the long steady window *is* the
  measurement; the snapshot series shows stabilization. The `sustained` subcommand has no
  `--warmup-secs`/`--settle-secs` args.
- `supports()` is unchanged: all three systems implement the `sustained` subcommand
  (`ApiStyle` covers durable/ursula/s2).
- Row values: `thr_or_evps` = `aggregate_ops_per_sec`, `p99_ms` = latency p99 — both
  already produced from the merged JSON by the existing `run_one` parsing.

### 2. Server-memory columns — parallel to `cpu_pct`

No new collection — `rss_bytes` is already in `samples.csv` and already collected.

- New helper in `lib-bench.sh`, modeled on `compute_server_cpu_pct` (reads column 2):

  ```sh
  # compute_server_mem_mb SAMPLES_CSV — prints "PEAK_MB DRIFT_MB" from rss_bytes.
  #   peak  = max(rss)               (high-water mark)
  #   drift = rss(last) - rss(first) (growth over the window; can be negative)
  compute_server_mem_mb() {
    awk -F',' '
      NR==1 { next }
      NR==2 { r0=$2; peak=$2; next }
      { rl=$2; if ($2>peak) peak=$2 }
      END {
        if (r0=="") { print "0 0"; exit }
        printf "%.0f %.0f\n", peak/1048576, (rl - r0)/1048576
      }' "$1"
  }
  ```

- `gke-bench.sh`:
  - Summary header gains two columns: `…\tcpu_pct\tmem_peak_mb\tmem_drift_mb`.
  - `run_one` reads `mem_peak`/`mem_drift` from `compute_server_mem_mb "$cd/samples.csv"`
    (default `0 0` when no samples) and appends both to the row `printf`.
- Like `cpu_pct`, these columns populate for **every** workload (write/sse/replay/
  sustained) and are sidecar-instrumented for **durable only**; `ursula`/`s2` report `0`.
  Extend the existing KNOWN LIMITATION comment to cover memory.

### 3. Docs / housekeeping

- Update the `gke-bench.sh` header comment block: WORKLOADS list, methodology note for
  sustained, and the two new memory columns.
- Update `BENCHMARKING.md`: the stale `scripts/gke-sustained.sh` reference (now in
  `legacy/`) points at the folded-in workload.

## Validation — local only

On local kind (`DS_TARGET=local`), no remote GKE:

1. `scripts/cluster-up.sh` (local kind) + build/load the durable image.
2. Smoke run:
   `DS_TARGET=local SYSTEMS=durable:strict WORKLOADS=sustained SUSTAINED_CARDS=10 SUSTAINED_DURATION=20 REPEATS=1 scripts/gke-bench.sh`
3. Assert: a `durable-strict-sustained-n10` cell runs; `summary.tsv` has the two new
   columns populated with non-zero `mem_peak_mb`; `samples.csv` exists per cell.
4. Regression: confirm the existing `write` workload still produces rows with the new
   columns (no schema break) — e.g. `WORKLOADS=write WRITE_CARDS=1000`.

Comparison systems (ursula/s2) and the full default matrix stay out of local validation
(remote-only / long-running); local runs only prove the wiring.

## Out of scope

- No changes to `sustained.rs` itself.
- No new Python renderer for `summary.tsv` (none exists today).
- No remote GKE execution in this branch.
- No deletion of `scripts/legacy/gke-sustained.sh` (kept as legacy reference).
