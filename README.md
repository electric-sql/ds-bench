# ds-rust-bench — single-node streaming-server benchmarks

Reproducible single-node comparison of three streaming servers — **durable-streams** (Rust),
**ursula**, and **S2 (s2lite)** — across four workloads:

| Workload | What it measures | Suites / entry |
| --- | --- | --- |
| **write throughput** | append/s at saturation (+ tail latency) | `suites/write-throughput-{wal,memory,ursula,s2}.json` |
| **sustained load** | latency + server-memory stability over time | `suites/sustained.json` |
| **catch-up / reconnect** | per-client catch-up latency + body size | `suites/catchup-{durable,ursula,s2}.json` |
| **SSE fan-out** | per-event delivery latency vs subscriber count | `scripts/run-sse.sh` |

Final results: **[`results/final/REPORT.md`](results/final/REPORT.md)**.

The load generator is **`ds-bench`**, derived from ursula's `ursula-bench` (Apache-2.0): the
per-client measurement logic is upstream's, unchanged; our additions are the multi-stream /
sustained / catch-up drivers and additive HDR-histogram file output for exact cross-fleet merge.

## How it works

A suite is a JSON file (`suites/*.json`) declaring the workload, the systems/configs, and the
sweep. `scripts/bench` brings up a cluster, deploys each server fresh, drives a Kubernetes
client fleet, merges per-pod HDR histograms into fleet-wide percentiles, records per-cell
results under `results/<suite>/`, and tears down. Reports are regenerated from local results
with no cluster.

- **write throughput** ramps client pods up a per-cardinality ladder until throughput plateaus
  (a *saturation walk*), then pins + confirms the peak.
- **sustained** holds a fixed low rate for `duration_secs` and records latency + server RSS drift.
- **catch-up** reproduces ursula's published reconnect methodology
  ([ursula.tonbo.io/benchmark](https://ursula.tonbo.io/benchmark)): N clients each reconnect to
  their **own** pre-populated stream and catch up via that system's native path — ursula
  `GET /bootstrap` (snapshot+tail), durable `offset=-1`, and s2 `/records` (full-log replay).
- **SSE fan-out** drives one writer + many subscribers and measures end-to-end delivery latency.

## Prerequisites

- `kubectl`, `python3` (3.x, stdlib only), Docker.
- **Local:** [kind](https://kind.sigs.k8s.io/).
- **Remote:** `gcloud` authenticated; an Artifact Registry repo. Override `PROJECT`
  (defaults to `gcloud config get-value project`), `AR_LOCATION` (default `europe-west1`),
  `AR_REPO` (default `ds-bench`), `ZONE`, and machine types (`SERVER_MACHINE`,
  `CLIENT_MACHINE`) for your environment.
- The server source (`durable-streams`) checked out alongside this repo for image builds;
  `vendor/ursula` is a pinned submodule (`git submodule update --init --recursive`).

## Quick start (local kind)

```bash
DS_TARGET=local scripts/cluster-up.sh     # kind cluster + MinIO + metrics ConfigMap
DS_TARGET=local scripts/build-images.sh   # build server + ds-bench images, load into kind

scripts/bench suites/write-throughput-wal.json run      # run a workload
scripts/bench suites/write-throughput-wal.json report   # (re)generate its report

DS_TARGET=local scripts/cluster-down.sh   # tear down
```

`run` provisions a cluster, executes the sweep, writes `results/<suite>/`, and tears down on
clean completion (`BENCH_KEEP_CLUSTER=1` to keep it). Re-running resumes / skips finished cells.

## Remote (GKE)

```bash
PROJECT=my-project scripts/build-images.sh        # Cloud Build → Artifact Registry
PROJECT=my-project scripts/bench suites/write-throughput-wal.json run
```

`scripts/cluster-up.sh` (invoked by `bench`) creates a server node pool (one node, server
CPU-pinned) and a Spot client pool. See `scripts/target-env.sh` for all overridable env
(registry, zone, machine types, pull policy). Remote clusters are billable — they tear down on
clean completion; `scripts/teardown-watchdog.sh` is a deadline safety net.

## Systems & configs

- **durable-streams** — `--durability wal` (WAL-backed, sharded committer) or `--durability memory`
  (no WAL). Separate suites: `write-throughput-wal.json`, `write-throughput-memory.json`.
- **ursula** — single-node Raft; backend selected by `URSULA_WAL`:
  `URSULA_WAL=memory scripts/bench suites/write-throughput-ursula.json run` (in-memory, no fsync)
  vs `URSULA_WAL=disk …` (disk WAL, fsync per commit). Default `disk`.
- **S2 (s2lite)** — object-store-backed (writes through to MinIO); `suites/write-throughput-s2.json`.

All servers point at the same single-node MinIO; only one server runs during its own measurement.

## Results & reproducing

- Raw per-cell data (`cells.json`, merged HDRs, sidecar `samples.csv`) → `results/<suite>/`.
- Curated final dataset + report → `results/final/`.
- Regenerate a report any time: `scripts/bench suites/<suite>.json report` (catch-up:
  `python3 scripts/catchup_report.py suites/catchup-*.json`; SSE: see `scripts/run-sse.sh`).

## Tests

Framework logic is unit-tested, no cluster required:

```bash
cd scripts && for t in *_test.py; do python3 "$t"; done
for t in scripts/*_test.sh; do bash "$t"; done
```

Covers the suite loader, per-cell result stores, the saturation classifier, the
catch-up/sustained runners, and the report renderers.

## Fairness & disclosure

- **Equal:** one node each; identical workload parameters; all three servers share the same
  single-node MinIO; only the system under test runs during its measurement. ds-bench uses
  ursula-bench's per-client measurement logic unchanged.
- **Matched durability:** ursula `disk` (Raft WAL, fsync per commit) vs durable-streams `wal`
  (fsync per append, coalesced across concurrent writers) — apples-to-apples for durable writes;
  `ursula:memory` / `durable:memory` are the non-durable best cases.
- **S2 is architecturally different:** it writes through to object storage on the hot path
  (every append makes a MinIO round-trip), so its write latency includes work the others defer
  to background tiering. The benchmark surfaces this; it is not a tuned handicap.
- **Single-node only:** this deliberately strips ursula's Raft *replication* (its headline
  feature) — durable-streams has no multi-node mode yet. Published multi-node numbers are not
  reused; everything here is generated by `ds-bench` on equal single-node hardware.
- Data directories are container-ephemeral by design: each run starts fresh (no cross-run
  contamination) while still exercising durability within a run.
