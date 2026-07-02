# Benchmark provenance — 2026-07-02

Full matrix on the **perf-branch** durable build, from scratch. First campaign to
include the mixed read/write interference workload (PR electric#4679 has the local
validation this extends).

## Versions (commit hashes)
- **durable-streams**: `330ccd1b09a2a2429e10ec3b6eeb0dacbf6e60b5`
  (branch `bench/mixed-interference-validation` = `perf/combined-t1a-t1c-t2a` head, PR #4679).
  Image `europe-west1-docker.pkg.dev/vaxine/ds-bench/durable-streams:dev`, built 2026-07-02 via Cloud Build from the crate checkout.
- **ds-bench**: `60ab813c26c7165ad3b9f6451d2ae94dbbc15fad` (mixed workload harness).
- **ursula**: `ghcr.io/tonbo-io/ursula:v0.1.5` · **Node.js reference**: `durable-node:dev` · **S2**: `ghcr.io/s2-streamstore/s2`

## Workloads
- **Write** saturation: `run-durable` (wal, wal-tailcache, memory — streams up to
  **500k**), `run-ursula` (memory, disk), `run-node`, `run-s2`.
- **SSE fan-out**: `run-sse.sh` — subscribers 1/10/100/1000, **no tailcache variant**
  (single-stream fan-out is a micro-benchmark; spread fan-out is mixed-delivery's job).
- **Reads**: `reads-catchup`, `reads-sse-remote` (wal + ursula; long-poll dropped this run).
- **Mixed interference** (NEW): `mixed-cal` (ceiling anchor), `mixed-writes`
  (readers 0→**100k**, one staggered replay/30s each, vs a 60%-pinned write load over
  10k streams), `mixed-writes-hot` (unpaced adversarial), `mixed-delivery`
  (2000 SSE subscribers over 2000 streams vs write-rate ladder, wal + memory).

## Hardware
Server `c4d-standard-16-lssd` pinned to 4 CPUs; client fleet `n2d-standard-32` Spot. europe-west4.

## Run notes (2026-07-02)

- **Server binary source**: branch head `330ccd1b09a2a2429e10ec3b6eeb0dacbf6e60b5`
  at build time; code identical to `perf/combined-t1a-t1c-t2a` head `06a8a37c5`
  (the extra commit is docs-only: MIXED_WORKLOAD_VALIDATION.md).
- **s2**: the 1000-stream write cell creation-choked 3x (incl. once from a fully
  clean slate: bucket wiped with s2lite stopped). Scoped run-s2 to 100 streams;
  the 1000 cell is a gap, not a zero.
- **mixed-writes retries**: readers=1000 failed once on Spot-fleet scheduling;
  readers=100000 OOMKilled the fleet pod at the old 4Gi cap (~110k task futures +
  per-reader HDR histograms). Fixed by raising the fleet memory cap to 24Gi
  (gke/bench-job.yaml); both levels re-ran clean.
- **200k write cells** are ladder-bounded lower bounds (200k ladder tops at 250
  pods vs 500k's 625; every config reads higher at 500k than 200k).
- **Interruptions**: the harness kills background tasks at 2h; the campaign was
  SIGTERMed twice (trap tore clusters down cleanly both times) and resumed with
  RESUME=1 — no measured cells lost. Final relaunch ran detached (nohup).
- **reads-catchup** high-connection error cells are the documented client-pod OOM
  ceiling (AGENTS.md §8), not server data: wal n10/n100 conn>=128, ursula n100 all.
- Headline synthesis: see REPORT.md alongside this file.
