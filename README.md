# ds-rust-bench — a benchmarking system for durable streams

A reproducible, single-node benchmark harness for durable-stream servers: declarative workload
suites, a Kubernetes client fleet, and exact cross-fleet HDR-percentile merging — runnable on a
local kind cluster or on GKE. Workloads are server-agnostic and run against any supported
implementation.

**Currently supported implementations:** **durable-streams** (Rust), **ursula**, **S2 (s2lite)**.

| Workload | What it measures | Suites / entry |
| --- | --- | --- |
| **write throughput** | append/s at saturation (+ tail latency) | `suites/write-throughput-{wal,memory,ursula,s2}.json` |
| **sustained load** | latency + server-memory stability over time | `suites/sustained.json` |
| **catch-up / reconnect** | per-client catch-up latency + body size | `suites/catchup-{durable,ursula,s2}.json` |
| **SSE fan-out** | per-event delivery latency vs subscriber count | `scripts/run-sse.sh` |

A sample run across the supported implementations: **[`results/final/REPORT.md`](results/final/REPORT.md)**.

The load generator is **`ds-bench`**, derived from ursula's `ursula-bench` (Apache-2.0): the
per-client measurement logic is upstream's, unchanged; our additions are the multi-stream /
sustained / catch-up drivers and additive HDR-histogram file output for exact cross-fleet merge.

## How it works

A suite is a JSON file (`suites/*.json`) declaring the workload, the systems/configs, and the
sweep. `scripts/bench` brings up a cluster, deploys each server fresh, drives a Kubernetes
client fleet, merges per-pod HDR histograms into fleet-wide percentiles, records per-cell
results under `results/<suite>/`, and tears down. Reports are regenerated from local results
with no cluster.

- **write throughput** — concurrent appends across N streams; the client fleet ramps up a
  per-cardinality pod ladder until server throughput plateaus (a *saturation walk*), then pins
  and confirms the peak append/s and its tail latency.
- **sustained** — a fixed append rate across N streams held for `duration_secs`; records latency
  and server-memory (RSS) drift over the window.
- **catch-up / reconnect** — a stream is pre-populated, then N clients reconnect and replay it
  from the start simultaneously; records per-client catch-up latency, response body size, and
  aggregate replay throughput. Each implementation replays via its native read path (snapshot+tail
  or full-log).
- **SSE fan-out** — one writer publishes to a stream while many subscribers stream it; records
  per-event end-to-end delivery latency versus subscriber count.

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

# `*-local` suites use small ladders/counts that fit a single kind node:
DS_TARGET=local scripts/bench suites/write-throughput-local.json run     # run a workload
DS_TARGET=local scripts/bench suites/catchup-local.json run              # another workload
scripts/bench suites/write-throughput-local.json report                  # (re)generate its report

DS_TARGET=local scripts/cluster-down.sh   # tear down
```

`DS_TARGET=local` runs everything against the kind cluster (no cloud, no teardown of kind).
The full `suites/*.json` are sized for a multi-node GKE cluster; for kind use the `*-local`
suites (or copy one and shrink `stream_counts` / `pod_ladder` / `clients`). `run` writes
`results/<suite>/`; re-running resumes / skips finished cells.

## Remote (GKE)

```bash
PROJECT=my-project scripts/build-images.sh        # Cloud Build → Artifact Registry
PROJECT=my-project scripts/bench suites/write-throughput-wal.json run
```

`scripts/cluster-up.sh` (invoked by `bench`) creates a server node pool (one node, server
CPU-pinned) and a Spot client pool. See `scripts/target-env.sh` for all overridable env
(registry, zone, machine types, pull policy). Remote clusters are billable — they tear down on
clean completion; `scripts/teardown-watchdog.sh` is a deadline safety net.

## Supported implementations

A workload runs against any supported server; the suite's `modes` + server image pick which one.
Currently supported:

- **durable-streams** — `--durability wal` (WAL-backed, sharded committer) or `--durability memory`
  (no WAL). Suites: `write-throughput-wal.json`, `write-throughput-memory.json`.
- **ursula** — single-node Raft; `URSULA_WAL` selects the backend —
  `URSULA_WAL=memory scripts/bench suites/write-throughput-ursula.json run` (in-memory) vs
  `URSULA_WAL=disk …` (disk WAL, fsync per commit). Default `disk`.
- **S2 (s2lite)** — object-store-backed; `suites/write-throughput-s2.json`.

All servers point at the same single-node MinIO; only the system under test runs during its
measurement. Adding an implementation is a deploy manifest, a `ds-bench` API style, and a few
addressing lines in `deploy_mode` / `reset_state` (`scripts/lib-bench.sh`).

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

- **Equal footing:** one node per server, identical workload parameters, a shared single-node
  MinIO, and only the system under test running during its measurement. Per-client measurement
  logic is ursula-bench's, unchanged.
- **Single-node only:** no replication is exercised; every number is generated by `ds-bench` on
  equal hardware, not reused from any implementation's published results.
- **Implementations differ architecturally** (e.g. an object-store-backed server makes a storage
  round-trip on every append where others defer to background tiering). The benchmark surfaces
  those differences rather than tuning them away — match `modes`/configs to compare like for like.
- **Fresh state:** data directories are container-ephemeral — each run starts clean (no cross-run
  contamination) while still exercising durability within a run.
