# Single-node benchmark: durable-streams vs ursula

**Date:** 2026-06-17
**Status:** Approved design, pending implementation plan
**Repo:** `ds-rust-bench`

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
| Workloads | All three: `multi-stream`, `fanout`, `bootstrap` |
| Benchmark client | Reuse ursula's `ursula-bench` (HTTP-only, multi-backend) |
| ursula-bench sourcing | Git submodule pinned to a SHA + small patch if a new `ApiStyle` is needed |

## Components (this repo)

```
ds-rust-bench/
├── docker-compose.yml         # minio, durable-streams, ursula, bench
├── dockerfiles/
│   ├── durable-streams.Dockerfile
│   ├── ursula.Dockerfile
│   └── bench.Dockerfile
├── config/
│   ├── ursula.toml            # single-node persistent + s3 cold tier
│   └── durable-streams.env    # --tier-* flags / env for MinIO offload
├── vendor/ursula/             # git submodule, pinned SHA (source of ursula + ursula-bench)
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
  config (fsync to disk, see open item 1), S3 cold tier pointed at MinIO.
- **bench** — `ursula-bench`, run on demand against one target at a time.

## Fairness controls

- Single node for both servers.
- Identical container CPU/memory limits.
- Servers run **one at a time** — never co-located during a measured run, to avoid
  resource contention.
- Both fsync to local disk; both offload sealed segments to the **same** MinIO bucket.
- Identical `ursula-bench` parameters across targets: stream count, duration,
  payload bytes, concurrency, warmup.

## Reusing ursula-bench

`ursula-bench` is a pure HTTP client (reqwest, no server-crate linkage) with a
pluggable `--api-style {ursula | durable | s2}`. Plan:

1. Build `ursula-bench` from the pinned ursula submodule.
2. **Verify** whether `--api-style durable` (URL shape `/v1/stream/{stream}`) maps
   cleanly onto durable-streams' request/response. durable-streams treats arbitrary
   paths as stream URLs, so it likely works as-is.
3. If headers/paths differ, add a small `durable-streams` `ApiStyle` variant in
   `backend.rs`, maintained as an auditable patch on the pinned SHA.

The three workloads, latency math (hdrhistogram), and JSON output are all
system-agnostic and reused unchanged.

### Workloads

- **multi-stream** — N concurrent streams, one writer each. Aggregate + per-stream
  ops/sec and a write-latency HDR summary. Primary throughput story; stand up first
  as the smoke test.
- **fanout** — one stream, many SSE subscribers, one writer. End-to-end per-event
  fan-out latency (writer embeds a send timestamp; subscriber records `now - sent`).
- **bootstrap** — many clients replay a stream after a snapshot. Catch-up/replay
  throughput; durable-streams' sendfile/io_uring zero-copy read path is expected to
  shine here.

## Open items (resolved during planning/implementation, not blocking)

1. **Ursula single-node persistent config** — confirm ursula can fsync to disk
   without a full multi-node Raft cluster (e.g. a 1-node Raft group that still
   writes its log to disk, or a disk WAL persistence mode). This determines the
   exact `ursula.toml`. The in-memory `default` preset is explicitly **not** used.
2. **`--api-style durable` fit** vs needing a new `ApiStyle` variant.
3. **durable-streams MinIO flags** — exact `--tier-endpoint`, `--tier-bucket`,
   `--tier-region`, `--tier-path-style true`, `--tier-allow-http true`,
   `--tier-segment-bytes`, and credential env (`DS_S3_ACCESS_KEY_ID` /
   `DS_S3_SECRET_ACCESS_KEY`).
4. **CPU/memory pinning** values for stable, fair runs.

## Deployment evolution (designed later)

- **Phase 2:** promote the same compose to a single Linux cloud VM (unlocks
  durable-streams' `io_uring` engine), then to representative hardware (e.g. AWS
  `c7g`, matching ursula's published test class) for publishable numbers.
- **Phase 3:** once durable-streams has multi-node, compare 3-node ↔ 3-node so
  ursula's replication is included.

## Success criteria (phase 1)

- `docker-compose` brings up MinIO + a chosen server; `ursula-bench` runs all three
  workloads against it and writes JSON results.
- Both servers verified to actually offload sealed data to MinIO (objects appear in
  the bucket).
- A rendered markdown table compares the two servers across the three workloads.
- README documents exact configs and the single-node fairness disclosure.
