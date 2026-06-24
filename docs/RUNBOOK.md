# Benchmark Runbook (write-throughput saturation suite)

## Prerequisites
- `gcloud` authenticated to project `vaxine`; `kubectl`, `python3` (3.x, stdlib only).
- Server + ds-bench images built and pushed (see BENCHMARKING.md).

## 1. Edit the suite (one suite per mode)
Throughput is split into one suite per mode, each on its own cluster/zone:
- `suites/write-throughput-wal.json`    → cluster `bench-wal`    (zone a)
- `suites/write-throughput-ursula.json` → cluster `bench-ursula` (zone b)
- `suites/write-throughput-s2.json`     → cluster `bench-s2`     (zone c)

Each declares its mode, stream-counts, the per-stream-count `pod_ladder`, and cluster
machine types (ladder first rung = seed, last = climb ceiling). The **wal** suite also
carries a `server_configs` sweep — `wal` (shards 4) and `wal-tailcache` (shards 4 +
64 KiB tail-cache) — which appear as **side-by-side columns** in its report.

## 2. Run (idempotent + resumable)
    scripts/bench suites/write-throughput-wal.json    run
    scripts/bench suites/write-throughput-ursula.json run
    scripts/bench suites/write-throughput-s2.json     run
- Each suite brings up its own **persistent** cluster (own zone + KUBECONFIG). The
  three are independent — run them concurrently in separate terminals, or one at a time.
- For each (label, stream-count) it ramps pods up the ladder until throughput plateaus
  (<`plateau_pct`), pins + confirms with `repeats` reps. CPU is a secondary signal for
  wal only (ursula/s2 have no cpu_pct). A `label` is a server-config variant (e.g.
  `wal` vs `wal-tailcache`); a mode with no `server_configs` has one baseline label.
- State + results: `results/<suite>/<label>/cells.json`. Re-running **skips saturated
  cells**, **resumes** ladder-exhausted ones (extend that stream-count's ladder upward
  in the JSON first), and **re-runs** cells whose server image OR config args changed.

## 3. Parallelization strategy
- Each suite owns one cluster; a finished label/cell is never re-run.
- Within a suite, cells run sequentially (one server at a time per cluster); server-config
  variants run sequentially too (redeploy the server with the variant's args between them).
- Suites are fully independent — if one cluster fails, re-run that suite to resume.

## 4. Known issues
- **100k creation-choke:** ~200–300 concurrent pods can break `PUT /v1/stream`; such
  cells are recorded `status:error` (never a fake ceiling) and flagged in the report.
- **s2** state lives in MinIO — its reset empties the `s2-bench` bucket as well as
  restarting the `s2lite` pod.

## 5. Report (per suite)
    scripts/bench suites/write-throughput-wal.json report
Writes `results/<suite>/aggregate.{csv,json}` + `report.md` (one column per label, so the
wal report shows `wal` vs `wal-tailcache` side by side; plus per-cell saturation walks +
empty Findings/Caveats for the narrative). Regenerable any time, no cluster needed.

## 6. Teardown
**Automatic on clean completion.** When `run` finishes, it collects + aggregates
results (`report.md`) and then tears the suite's cluster down **only if every cell
finished cleanly** (`report.suite_status` == `complete`). If any cell is `error`
or a cell is missing, the cluster is **kept** for investigation / resume (re-run to
resume; it tears down once the suite is clean). Results are always local before any
teardown (per-cell `merged.json`/`samples.csv` are pulled during the walk).
- `BENCH_KEEP_CLUSTER=1 scripts/bench <suite> run` — never auto-teardown.

**Manual, per suite:**
    scripts/bench suites/write-throughput-wal.json teardown              # delete now
    scripts/bench suites/write-throughput-wal.json teardown-if-complete  # delete only if clean
Deletes **only** the clusters that suite created (tracked in `.bench-state/<suite>.json`),
and clears that state file.

## 7. Unattended full run (all configs, guaranteed teardown)
    nohup scripts/teardown-watchdog.sh > .bench-state/watchdog.log 2>&1 & disown   # arm safety net first
    nohup scripts/run-all.sh           > .bench-state/run-all.log  2>&1 & disown
- `run-all.sh` runs every `suites/write-throughput-*.json` **sequentially**, each with
  `BENCH_KEEP_CLUSTER=1` + an explicit teardown afterward (so an expected error like a
  100k choke never strands a cluster), bounded by `PER_SUITE_TIMEOUT` (default 3h). It
  sweeps any leftover `bench-*` clusters, then writes the cross-config report
  `results/combined-report.md` (+ `results/combined.csv`) and touches
  `.bench-state/run-all.done`. Uses `PULL_POLICY=IfNotPresent` so per-rung restarts reuse
  the node-cached image.
- `teardown-watchdog.sh` is the **hard-deadline safety net**: it force-deletes ALL
  `bench-*` clusters at `DEADLINE_SECS` (default 8h) UNLESS `.bench-state/run-all.done`
  appears first. Launch it detached so it survives a hang/crash of the orchestration.
- Final results: `results/combined-report.md` (peak throughput per configuration),
  per-suite `results/<suite>/report.md`, and raw per-cell `merged.json`/`samples.csv`.

## 8. Tests
The benchmark logic is unit-tested (stdlib `unittest`, matching the repo's existing
test files — no pytest dependency):

    cd scripts && for t in suite_test.py saturation_test.py saturation_step_test.py \
        cells_test.py render_common_test.py report_test.py; do python3 "$t" || exit 1; done
    for t in scripts/*_test.sh; do bash "$t" || exit 1; done
