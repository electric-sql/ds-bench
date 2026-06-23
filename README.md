# ds-rust-bench — Track 1: single-node comparison

Reproducible single-node benchmark of **durable-streams** (Rust) vs **ursula** vs **S2 Lite**,
under matched durability, driven by `ds-bench` — **derived from ursula's own `ursula-bench`**
(Apache-2.0). See the design spec at
`docs/superpowers/specs/2026-06-17-single-node-bench-design.md`.

## Quick start

The comparison is one matrix runner — **`scripts/gke-bench.sh`** — that deploys each
system fresh per cell, warms up + settles, measures, and writes one
`results/bench/bench-<ts>/summary.tsv`. The same commands run on a local kind cluster
or a remote GKE cluster, selected by `DS_TARGET`.

```bash
git submodule update --init --recursive               # pulls vendor/ursula @ pinned SHA

DS_TARGET=local scripts/cluster-up.sh                  # cluster + MinIO + metrics ConfigMap
scripts/build-images.sh                                # build/load images (server built with
                                                       # FEATURES=tier,strict-uring; remote: gke-push-images.sh)
DS_TARGET=local CLUSTER=ds-bench scripts/gke-bench.sh  # the full matrix
scripts/cluster-down.sh                                # tear down (always, for remote)
```

See **[BENCHMARKING.md](BENCHMARKING.md)** for the full runbook — knobs, calibrate-then-pin,
the per-cluster matrix, and rendering.

## The matrix

Each cell is a fresh deploy + warm-up + settle + measure, **averaged over 3 reps**. Server
durability mode only affects the write path, so the **read** workloads (SSE, replay) run a
single durable config (`wal`); **write** runs all three.

| Workload | Sweep | Systems / configs | Metric |
| --- | --- | --- | --- |
| **write** | 1k / 10k / 100k streams | durable `strict`·`strict-iouring`·`wal`, ursula `memory`, s2 | ops/s + p99 |
| **sse** | 1 stream × {1,10,100,1000} subscribers (Ursula-style) | durable `wal`, ursula `memory`, s2 | delivery p99 |
| **replay** | 1000 clients × 200 events | durable `wal`, ursula `memory` (s2 excluded) | p99 |

Durable runs the Linux-optimal config: `--splice-appends`, `--read-offload tail`, tail
cache off (Linux default), `--tier s3`. `cpu_pct` is instrumented for durable only
(ursula/s2 server CPU is a known limitation). The table above lists the default
`SYSTEMS`; for a durability-matched write comparison add `ursula:disk` (fsync per commit)
and compare durable's fsync modes (`strict`/`strict-iouring`/`wal`) against it, with
`ursula:memory` as ursula's best case. See **[Systems & variants](#systems--variants)**
below for the full catalog (including the opt-in `wal-cache`/`strict-cache` read-cache
variants).

## What is measured

`ds-bench` is **derived from ursula-bench** (Apache-2.0). The per-client **measurement
logic is ursula's, unchanged**; our only edits to the upstream workloads are **additive
output** — each workload also serializes its HDR histogram to a file (for exact
cross-fleet merge in Track 2) when `DS_BENCH_HDR_OUT` is set. Verifiable as a small
additive diff that touches no measurement code. `catch_up.rs` and `mixed.rs` are our own.

`ds-bench` drives three workloads against all three systems, each emitting HDR-histogram latency +
throughput JSON:

- **multi-stream** — N concurrent streams, one writer each (write throughput + latency).
- **fan-out** — one stream, many SSE subscribers (end-to-end per-event latency).
- **catch-up** — N clients simultaneously replay a pre-loaded stream from offset 0 until
  `Stream-Up-To-Date` (replay throughput + latency). This is our own protocol-faithful
  workload: it uses the DS-protocol offset read (not ursula's snapshot-based
  `/bootstrap`/`/snapshot/{offset}` endpoints, which have no DS-protocol equivalent),
  and runs symmetrically against durable-streams and ursula. **S2 Lite is excluded from
  the catch-up comparison** because its native replay (`GET ?seq_num=0&bytes=N`) is a
  paginated, JSON/base64-enveloped read that is not directly comparable to the Durable
  Streams servers' full-replay loop; S2 is compared on multi-stream (writes) and
  fan-out (SSE latency).

Note: ursula-bench's `bootstrap` workload is **not** used here because it relies on
ursula-specific routes absent from `PROTOCOL.md`. What remains deferred to Track 2 is
the larger scale-out comparison (multi-node, higher client counts).

## Fairness — what is equal, and what is not

- **Equal:** single node each; **ursula's own measurement logic, unchanged** (per-client
  measurement code derived from ursula-bench, Apache-2.0; only additive HDR-file output
  added — see provenance note above); identical workload parameters (see `run-bench.sh`);
  all three servers point at the same single-node MinIO instance. Only one server runs
  during its own measurement.
- **Matched durability (durable-streams & ursula):** ursula runs a single-voter Raft
  group with `[raft.wal] backend = "disk"` (fsync per commit); durable-streams fsyncs
  per append. **Both group-commit fsyncs** (ursula: 200µs/1024-record window;
  durable-streams: coalesced across concurrent writers), so this is apples-to-apples
  for concurrent writes; under serial load both approach one fsync per append. The
  hot-path write lands on **local disk** first; sealed/cold segments are offloaded to
  MinIO asynchronously.
- **Durability substrate disclosure — S2 Lite:** S2 Lite is architecturally different.
  It writes through **SlateDB** to object storage (MinIO) on the write path with a
  default flush interval of ~50 ms. Every acknowledged append has already made a MinIO
  round-trip; there is no local-disk fsync hot path. This means S2 Lite's write
  latency includes an object-store write that durable-streams and ursula defer to
  background tiering. This is an architectural difference the benchmark surfaces, not
  a tuned handicap — all three point at the same single-node MinIO.
- **S2 catch-up is excluded** (not just caveated): S2's native replay
  (`GET ?seq_num=0&bytes=N`) is a paginated, JSON/base64-enveloped read that is neither
  a full single-pass replay nor byte-comparable to the DS-protocol full-replay loop, so
  the catch-up section reports `-` for S2 and `ds-bench catch-up --api-style s2` fails
  fast by design. S2 is compared on multi-stream and fan-out only.
- **S2 fan-out:** S2's fan-out path is expected to be slower — SSE is not
  object-store-native and the write path already includes an object-store round-trip.
- **Not equal / disclosed:** single-node deliberately strips ursula's Raft
  *replication*, its headline feature — we benchmark single-node only because
  durable-streams has no multi-node yet. We do **not** reuse ursula's published
  numbers (3-node quorum, a `perf_compare` client not in the repo). All numbers here
  are generated by `ds-bench` on the same machine.

## Systems & variants

The full variant set deployed by `deploy_system()` in `scripts/gke-bench.sh` is the `system:variant` cells below. `durable:*` is our Rust server (variant = `--durability` mode, plus standalone read-path flags); `ursula:*`'s variant is the `[raft.wal] backend` value (set via `URSULA_WAL`); `s2` is S2 Lite. Default `SYSTEMS` runs `durable:strict durable:strict-iouring durable:wal ursula:memory s2:_`; the `-cache` variants are opt-in (add them to `SYSTEMS`).

| `system:variant` | Deploys (server flags) | When to use |
| --- | --- | --- |
| `durable:strict` | `--durability strict` | Per-stream group-commit fsync — the durable default. Each acknowledged append is on disk; concurrent writers coalesce into one fsync. The fsync-durability baseline. |
| `durable:strict-iouring` | `--durability strict --strict-io-uring` | Same group-commit fsync durability as `strict`, but the per-stream `fdatasync`s run through one shared io_uring ring instead of `spawn_blocking`. Use to isolate the io_uring fsync-executor delta on Linux (server must be built `--features strict-uring`; falls back to `spawn_blocking` if io_uring is unavailable). |
| `durable:wal` | `--durability wal --wal-shards N` | Sharded WAL committer (`N` = `WAL_SHARDS`, runner default 4). An alternative fsync-durability path that batches across a fixed shard set. Compare write throughput/p99 against `strict` at high cardinality. Reads (SSE/replay) run on this config because the read path is mode-independent. |
| `durable:wal-cache` | `--durability wal --wal-shards N --tail-cache-bytes B` | `wal` plus the resident tail read-cache ON (`B` = `TAIL_CACHE_BYTES`, runner default 65536). `--tail-cache-bytes` is a **standalone read-path flag** independent of the durability mode — the read path is identical across `strict`/`wal`, so the cache delta is mode-agnostic and affects only reads/SSE, never writes. Use to measure the tail-cache read delta. |
| `durable:strict-cache` | `--durability strict --tail-cache-bytes B` | `strict` plus the same resident tail read-cache. Same read-cache delta as `wal-cache` (the variant just labels which durability mode it rides on); the cache changes nothing on the write path. |
| `ursula:memory` | `[raft.wal] backend = "memory"` | In-memory Raft WAL, **no fsync** — ursula's best case. Compare against durable's durable modes (`strict`/`wal`) to show ursula's durability cost. |
| `ursula:disk` | `[raft.wal] backend = "disk"` | Disk Raft WAL, fsync per commit. **This is the durability-matched comparison** for durable's fsync modes (`strict`/`strict-iouring`/`wal`) — compare durable's fsync variants against `ursula:disk`, with `ursula:memory` as ursula's best case. |
| `s2` | `gke/s2lite.yaml` (S2 Lite, `--api-style s2 --basin benchmark`) | S2 Lite, object-store-native (writes through SlateDB to MinIO). Compared on write + SSE only (excluded from replay). |

## Configuration

- durable-streams: `--tier s3` → MinIO, plus the Linux-optimal `--splice-appends` + `--read-offload tail` (tail cache off, the Linux default); durability variants `strict`/`strict-iouring`/`wal` (plus opt-in `wal-cache`/`strict-cache`, which add the resident tail read-cache — a read-path-only delta). Image built `FEATURES=tier,strict-uring` (`dockerfiles/durable-streams.Dockerfile`).
- ursula: `config/ursula.toml` (`ds-bench/ursula:dev`, built from `vendor/ursula` @ `0b2d0da`).
- S2 Lite: compose service `s2lite`, host port 4439, `--api-style s2 --basin benchmark`; writes through SlateDB to MinIO.
- MinIO: `minioadmin`/`minioadmin`, buckets `durable-streams`, `ursula`, and `s2-bench` (S2 Lite; `benchmark` is its basin, not a bucket).

## Caveats

- `io_uring` (strict-mode fsync) is now compared on Linux: the `durable:strict-iouring`
  variant runs the server built `--features strict-uring` with `--strict-io-uring` (one
  shared io_uring ring batching per-stream `fdatasync`s), head-to-head against plain
  `strict` (spawn_blocking). The WAL io_uring path is deferred.
- All servers' data directories are **container-ephemeral by design**: each measured run starts from fresh state (no cross-run contamination), while durability (fsync for durable-streams/ursula; object-store flush for S2 Lite) is still exercised within a run. This is intentional, not a bug — it keeps runs reproducible.
