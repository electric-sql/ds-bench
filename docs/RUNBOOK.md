# Benchmark Runbook (write-throughput saturation suite)

## Prerequisites
- `gcloud` authenticated to project `vaxine`; `kubectl`, `python3` (3.x, stdlib only).
- Server + ds-bench images built and pushed (see BENCHMARKING.md).

## 1. Edit the suite
`suites/write-throughput.json` declares modes, stream-counts, the per-stream-count
`pod_ladder`, and cluster machine types. The ladder's first rung is the seed; the
last is the climb ceiling.

## 2. Run (idempotent + resumable)
    scripts/bench suites/write-throughput.json run
- Brings up one **persistent** cluster per mode (`bench-wal`/`bench-ursula`/`bench-s2`),
  in zones a/b/c, each with its own KUBECONFIG. Modes run in parallel.
- For each (mode, stream-count) it ramps pods up the ladder until throughput plateaus
  (<`plateau_pct`), pins + confirms with `repeats` reps. CPU is a secondary signal for
  wal only (ursula/s2 have no cpu_pct).
- State + results: `results/<suite>/<mode>/cells.json`. Re-running **skips saturated
  cells**, **resumes** ladder-exhausted ones (extend that stream-count's ladder upward
  in the JSON first), and **re-runs** cells whose server image digest changed.

## 3. Parallelization strategy
- Parallelism is **by mode** (separate clusters). A finished mode is never re-run.
- Within a mode, cells run sequentially (one server at a time per cluster).
- If one mode's cluster fails, the others continue; re-run `bench … run` to resume.

## 4. Known issues
- **100k creation-choke:** ~200–300 concurrent pods can break `PUT /v1/stream`; such
  cells are recorded `status:error` (never a fake ceiling) and flagged in the report.
- **s2** state lives in MinIO — its reset empties the `s2-bench` bucket as well as
  restarting the `s2lite` pod.

## 5. Report
    scripts/bench suites/write-throughput.json report
Writes `results/<suite>/aggregate.{csv,json}` + `report.md` (tables + per-cell saturation
walks + empty Findings/Caveats for you to write the narrative). Regenerable any time.

## 6. Teardown (deferred — explicit)
    scripts/bench suites/write-throughput.json teardown
Deletes **only** the clusters this suite created (tracked in `.bench-state/<suite>.json`).
Clusters otherwise persist between experiments.

## 7. Tests
The benchmark logic is unit-tested (stdlib `unittest`, matching the repo's existing
test files — no pytest dependency):

    cd scripts && for t in suite_test.py saturation_test.py saturation_step_test.py \
        cells_test.py render_common_test.py report_test.py; do python3 "$t" || exit 1; done
    for t in scripts/*_test.sh; do bash "$t" || exit 1; done
