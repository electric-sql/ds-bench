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

The four workloads exercise different parts of a durable-stream server. **Write throughput**
drives concurrent appends across many streams while the client fleet ramps up a per-cardinality
pod ladder; once server throughput stops climbing it pins and confirms the peak append rate,
the latency at that peak, and the server's peak pod memory — a *saturation walk* that finds the
server's ceiling rather than assuming a pod count. The memory figure is the pod cgroup working
set (anon + active page cache), so a resident cache and an OS-paging design are compared on
equal terms across every implementation. **Sustained load** instead holds a fixed, modest append rate across a set
of streams for a long window and watches whether latency and the server's resident memory stay
flat over time, surfacing slow drift or leaks that a short burst would miss. **Catch-up /
reconnect** pre-populates a stream and then has many clients reconnect and replay it from the
beginning all at once, recording how long each client takes to catch up, how large its response
is, and the aggregate replay throughput; each implementation replays through whatever native
read path it offers, whether a snapshot plus the tail since that snapshot or a full scan of the
log. **SSE fan-out** has a single writer publish to one stream while a growing number of
subscribers stream it, measuring the per-event end-to-end delivery latency as the fan-out widens.

## Prerequisites

- `kubectl`, `python3` (3.x, stdlib only), Docker.
- **Local:** [kind](https://kind.sigs.k8s.io/).
- **Remote:** `gcloud` authenticated; an Artifact Registry repo. Override `PROJECT`
  (defaults to `gcloud config get-value project`), `AR_LOCATION` (default `europe-west1`),
  `AR_REPO` (default `ds-bench`), `ZONE`, and machine types (`SERVER_MACHINE`,
  `CLIENT_MACHINE`) for your environment.
- The `durable-streams` server source checked out alongside this repo, only if you build its
  image yourself. ursula and S2 use upstream-published images
  (`ghcr.io/tonbo-io/ursula`, `ghcr.io/s2-streamstore/s2`) — no source to vendor.

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

A workload is server-agnostic: the same suite runs against any supported implementation, chosen
by the suite's `modes` and the server image that gets deployed. **durable-streams**, the Rust
server this harness was built alongside, runs either WAL-backed (`--durability wal`, a sharded
committer) or without a WAL (`--durability memory`), and its two modes have their own suites
(`write-throughput-wal.json` and `write-throughput-memory.json`). The **Node.js reference
server** (`@durable-streams/server`) is the protocol's reference implementation and speaks the
same wire protocol, so it reuses the `durable` API style and runs as mode `node` (in-memory
storage). Because it is TypeScript rather than a compiled binary, its image is built from the
same `../durable-streams` monorepo by installing the pnpm workspace and starting the server
under Node — see `dockerfiles/durable-node.Dockerfile`; `build-images.sh` builds it by default
(`BUILD_NODE=0` to skip). **ursula** is a single-node Raft server whose storage backend is
chosen at deploy time through the `URSULA_WAL` variable — `memory` keeps the log in RAM while
`disk` writes a WAL and fsyncs on every commit (the default) — so a single
`write-throughput-ursula.json` covers both. **S2**, run here as `s2lite`, is object-store-backed.
Every server points at the same single-node MinIO, and only the system under test is running
while it is measured. Adding another implementation comes down to a deployment manifest, a
`ds-bench` API style for its wire protocol, and a few addressing lines in `deploy_mode` and
`reset_state` in `scripts/lib-bench.sh`.

## Results & reproducing

Each run writes its raw per-cell data — the `cells.json` result-and-resume store, the merged HDR
histograms, and the sidecar `samples.csv` — under `results/<suite>/`, while the curated dataset
behind the sample report lives in `results/final/`. Reports are derived purely from those local
files and can be regenerated at any time without a cluster: use `scripts/bench suites/<suite>.json
report` for most workloads, `python3 scripts/catchup_report.py suites/catchup-*.json` for the
catch-up comparison, and `scripts/run-sse.sh` for SSE.

## Tests

Framework logic is unit-tested, no cluster required:

```bash
cd scripts && for t in *_test.py; do python3 "$t"; done
for t in scripts/*_test.sh; do bash "$t"; done
```

Covers the suite loader, per-cell result stores, the saturation classifier, the
catch-up/sustained runners, and the report renderers.

## Fairness & disclosure

These benchmarks target **single-node deployments**. Within that scope every run is kept on equal
footing — one node per server, identical workload parameters, a shared single-node MinIO, fresh
data each run, and only the system under test running while it is measured — and all numbers are
generated by `ds-bench` on equal hardware, not reused from any implementation's published results.

## Future work

Extend the harness to replicated and other deployment topologies; the current workloads and
suites assume a single node.
