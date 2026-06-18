# Single-node benchmark: durable-streams vs ursula

**Date:** 2026-06-17
**Status:** Approved design, pending implementation plan
**Repo:** `ds-rust-bench`
**Track:** 1 of 2 — single-node comparison. Ships first; de-risks
[Track 2: scale-out experiment](2026-06-17-scale-out-experiment-design.md).
Builds `ds-bench` v0, the shared workload client both tracks use.

## Purpose

Produce a reproducible benchmark harness that generates **our own** performance
numbers for both [durable-streams](../../../../durable-streams) (Electric's Rust
reference server) and [ursula](https://github.com/tonbo-io/ursula) (tonbo-io)
on a single node, under matched durability, for **competitive positioning**.

Both systems implement the same wire protocol — the Durable Streams Protocol over
HTTP + SSE — which makes a single client driving both targets feasible.

### Why single node

durable-streams has no multi-node support yet. ursula's headline feature is
quorum-replicated (Raft) durability. Benchmarking single-node deliberately strips
ursula's differentiator. This is acceptable and intended, but **must be disclosed
plainly** so the comparison is not read as cherry-picking. When durable-streams
gains multi-node, a 3-node ↔ 3-node comparison becomes the fair next step.

### Ground rules (competitive positioning)

- All numbers are generated **by us**, with the same client, on the same machine,
  running **one server at a time**.
- We do **not** cite ursula's published figures. Those used a 3-node Raft quorum
  and a `perf_compare` client whose flags do not match the in-repo `ursula-bench`
  source, so they are not auditable or apples-to-apples for our single-node axis.
- Configuration is committed and pinned; runs are reproducible.

## Locked decisions

| Decision | Choice |
| --- | --- |
| Goal | Competitive positioning (strict fairness + reproducibility) |
| Durability alignment | Both fsync to local disk + offload sealed data to MinIO (local S3), single node |
| Runtime | docker-compose, Linux containers (io_uring deferred to a real Linux host) |
| Workloads | Two: `multi-stream` (write throughput) + `fan-out` (SSE latency). Catch-up/replay deferred — see note below. |
| Benchmark client | **`ds-bench`** — **derived from** ursula-bench (Apache-2.0); measurement logic unchanged; additive HDR-file output added for Track 2 cross-fleet merge; multi-backend; shared with [Track 2](2026-06-17-scale-out-experiment-design.md) |
| ds-bench provenance | Workloads + HDR methodology derived from `ursula-bench` (Apache-2.0); ursula kept as a pinned submodule for reference + license attribution |
| ursula pinned commit | `0b2d0dabf0a6544b909823e0d1d1149b98274e25` (`v0.1.5-3-g0b2d0da`) |

## Components (this repo)

```
ds-rust-bench/
├── docker-compose.yml         # minio, durable-streams, ursula, bench
├── ds-bench/                  # our own Rust workload client (shared with Track 2)
│   ├── Cargo.toml
│   └── src/                   # derived from ursula-bench; measurement logic unchanged; only multi-stream + fan-out run in Track 1
├── dockerfiles/
│   ├── durable-streams.Dockerfile
│   ├── ursula.Dockerfile      # reuses ursula's own Dockerfile pattern
│   └── ds-bench.Dockerfile
├── config/
│   ├── ursula.toml            # single-node persistent + s3 cold tier
│   └── durable-streams.env    # --tier-* flags / env for MinIO offload
├── vendor/ursula/             # git submodule, pinned SHA (reference + Apache-2.0 attribution)
├── run.sh (or justfile)       # boot minio + one server, run 3 workloads, collect JSON
├── scripts/render-results.*   # JSON -> markdown comparison tables
├── results/                   # JSON outputs + rendered tables
└── README.md                  # methodology, exact configs, "what's equal / what isn't"
```

### Services (docker-compose)

- **minio** — S3-compatible object store ("local S3"), plus an `mc` init sidecar
  that creates the offload bucket on startup.
- **durable-streams** — built from `../durable-streams/packages/server-rust` with
  `--features tier`, `raw` HTTP engine (Linux), per-append fsync durability,
  `--tier s3` pointed at MinIO.
- **ursula** — built from the pinned ursula checkout, single-node **persistent**
  config: `[raft.wal] backend = "disk"` + empty `[raft.peers]` (a single-voter
  Raft group whose openraft log `fdatasync`s before acking each commit), S3 cold
  tier pointed at MinIO. See resolved open item 1.
- **bench** — `ds-bench`, run on demand against one target at a time.

## Fairness controls

- Single node for both servers.
- Identical container CPU/memory limits.
- Servers run **one at a time** — never co-located during a measured run, to avoid
  resource contention.
- Both fsync to local disk; both offload sealed segments to the **same** MinIO bucket.
- Identical `ds-bench` parameters across targets: stream count, duration,
  payload bytes, concurrency, warmup.
- **Group-commit symmetry (matched durability):** both servers coalesce fsyncs —
  ursula's durable Raft log group-commits within a 200µs / 1024-record window
  (`CORE_LOG_GROUP_COMMIT_*`); durable-streams group-commits fsyncs across
  concurrent writers. Each individual append is crash-durable on disk before its
  ack on both sides. So matched-disk is apples-to-apples for concurrent write
  workloads; under a serial workload both collapse to ~one fsync per append. The
  README must report the concurrency used and this group-commit equivalence.

## ds-bench v0 (shared client)

`ds-bench` is **derived from ursula-bench** (Apache-2.0). The per-client **measurement
logic is ursula's, unchanged**; our only edits to the upstream workloads are **additive
output** — each workload also serializes its HDR histogram to a file (for exact
cross-fleet merge in Track 2) when `DS_BENCH_HDR_OUT` is set. Verifiable as a small
additive diff that touches no measurement code. `catch_up.rs` and `mixed.rs` are our own.

Built in this track and **shared with Track 2** (the scale-out experiment extends it).
Packaging changes from upstream: standalone crate, pinned deps, the one
`ursula-observability::init` call swapped for `tracing-subscriber`. Owning the fork is
what lets Track 2 add new workloads (mixed/cardinality/resume) and cross-pod HDR merge.

- A pure HTTP client (reqwest, no server-crate linkage) with the upstream pluggable
  backend `--api-style {ursula | durable | s2}`, copied verbatim. The pinned ursula
  submodule stays for reference and Apache-2.0 attribution.
- The `durable` api-style (`/v1/stream/{stream}`) maps cleanly onto durable-streams
  for the two workloads below — create/append/SSE are byte-identical; durable-streams
  treats arbitrary paths as stream URLs. Confirmed: no api-style change needed (was
  open item 1).
- All three upstream workload modules are compiled into the binary (measurement logic
  unchanged; additive HDR-file output only), but **only `multi-stream` and `fan-out`
  run** in Track 1 (see note).

Forward-looking (built in Track 2, noted so v0's structure anticipates it):
serialized-HDR output for cross-node merge, and a backend/workload layout that
admits new workloads without touching existing ones.

### Workloads (Track 1)

- **multi-stream** — N concurrent streams, one writer each. Aggregate + per-stream
  ops/sec and a write-latency HDR summary. Primary throughput story; stand up first
  as the smoke test.
- **fan-out** — one stream, many SSE subscribers, one writer. End-to-end per-event
  fan-out latency (writer embeds a send timestamp; subscriber records `now - sent`).

### Why catch-up/replay is deferred (not `bootstrap`)

ursula-bench's third workload, `bootstrap`, is built around ursula's `/bootstrap`
(multipart snapshot+tail) and `/snapshot/{offset}` endpoints. **Neither is part of
the Durable Streams protocol** — `PROTOCOL.md` has no `/bootstrap` route and exactly
one passing mention of "snapshot" (no endpoint), and the DS server has no such
handlers. The DS equivalent of replay is a plain catch-up read (`GET ?offset=-1`
looped until `Stream-Up-To-Date`). So running `bootstrap` against DS would 404 on the
snapshot-publish step and isn't a faithful comparison. Catch-up/replay read
throughput (a DS strength via sendfile/io_uring) is worth measuring, but as a
**protocol-faithful workload of our own**, designed around catch-up reads and run
symmetrically — added in Track 2, not by bending ursula's snapshot-based stampede.

## Resolved: ursula single-node durable config (was open item 1)

Confirmed against ursula `0b2d0da`: single-node ursula persists durably to local
disk with fsync, **no multi-node cluster required**. Mechanism: a single-voter
Raft group whose on-disk openraft log `fdatasync`s (`sync_data`) before each commit
is acked. Enabled via `[raft.wal] backend = "disk"` + `path`, an empty
`[raft.peers]` (→ `Topology::SingleNode`), `node_id = 1`, on any non-`default`
preset. The in-memory `default` preset is explicitly **not** used.

`Persistence` and `Topology` are orthogonal (`crates/ursula/src/bootstrap/topology.rs`):
`SingleNode` + `Persistence::Raft { log_dir: Some(dir) }` is supported and exercised
by ursula's own tests. Cold S3 is the data tier and is **not** on the write-ack hot
path — per-append durability is entirely the local on-disk Raft log.

Minimal `config/ursula.toml`:

```toml
[server]
listen = "0.0.0.0:4437"

[raft]
node_id = 1                 # must be non-zero; peers omitted -> SingleNode

[raft.wal]
backend = "disk"            # durable, fsynced openraft log
path = "/var/lib/ursula/data"   # log dir becomes <path>/raft-log

[storage.cold]
backend = "s3"

[storage.cold.s3]
bucket = "ursula-bench"
endpoint = "http://minio:9000"
region = "us-east-1"
access_key_id = "minioadmin"
secret_access_key = "minioadmin"
```

Run: `ursula --config ursula.toml --preset standard` (consider lowering
`raft.group_count` from the preset default of 256 for a focused bench).

Caveat folded into the fairness controls above: the durable log group-commits
fsyncs (200µs / 1024-record window). durable-streams also group-commits, so this is
matched. There is a strict per-call-fsync `Persistence::Wal` engine in ursula, but
it is **not reachable via the shipped binary** (would need a custom library entry
point) and reopens the file per append, so we do not use it.

## Open items (resolved during planning/implementation, not blocking)

1. **durable-streams MinIO flags** — confirmed in the plan: `--tier s3
   --tier-endpoint http://minio:9000 --tier-region us-east-1 --tier-bucket … 
   --tier-allow-http` (path-style is the default); creds via env
   `DS_S3_ACCESS_KEY_ID` / `DS_S3_SECRET_ACCESS_KEY`.
2. **CPU/memory pinning** values for stable, fair runs (add compose
   `deploy.resources` / `--cpus` if runs prove noisy).

(`--api-style durable` fit is **resolved**: it maps cleanly onto durable-streams for
the two Track-1 workloads — no new `ApiStyle` variant needed.)

## Deployment evolution (designed later)

- **Phase 2:** promote the same compose to a single Linux cloud VM (unlocks
  durable-streams' `io_uring` engine), then to representative hardware (e.g. AWS
  `c7g`, matching ursula's published test class) for publishable numbers.
- **Phase 3:** once durable-streams has multi-node, compare 3-node ↔ 3-node so
  ursula's replication is included.

## Success criteria (phase 1)

- `docker-compose` brings up MinIO + a chosen server; `ds-bench` runs both
  workloads (multi-stream, fan-out) against it and writes JSON results.
- Both servers verified to actually offload sealed data to MinIO (objects appear in
  the bucket).
- A rendered markdown table compares the two servers across both workloads.
- README documents exact configs and the single-node fairness disclosure.
