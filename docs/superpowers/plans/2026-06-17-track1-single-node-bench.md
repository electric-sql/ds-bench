# Track 1: Single-Node Benchmark Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A reproducible docker-compose harness that runs `ds-bench` (a verbatim fork of ursula's `ursula-bench`) against durable-streams (Rust) and ursula on a single node, under matched durable-to-disk + MinIO offload, and emits comparable JSON + a markdown table for two workloads: write throughput and SSE fan-out latency.

**Architecture:** Build `ds-bench` v0 by forking `ursula-bench` into a standalone Rust crate with **packaging changes only** (no workload-logic changes) — the strongest "we ran ursula's own benchmark, unmodified" fairness story. Containerize durable-streams-server and ursula, plus MinIO as local S3. An orchestration script boots MinIO + one server at a time, runs the two workloads, and collects results. The `durable` api-style already maps byte-for-byte onto durable-streams for create/append/SSE.

**Tech Stack:** Rust (edition 2024 for ds-bench; edition 2021 for the DS server; edition 2024 for ursula), reqwest + hdrhistogram, Docker + docker-compose, MinIO, `jq` for assertions, Python 3 for the results renderer.

**Spec:** `docs/superpowers/specs/2026-06-17-single-node-bench-design.md`

## Global Constraints

- **Goal is competitive positioning** — every measured run holds the two servers at matched durability and runs **one server at a time**; the README must disclose what is equal and what is not.
- **ds-bench is a verbatim fork** — packaging changes only (standalone crate, pinned deps, swap the one `ursula-observability::init` call). **No workload logic, measurement methodology, or HDR math changes.** Any future divergence is flagged and documented.
- **Track 1 runs two workloads only:** `multi-stream` (write throughput) and `fan-out` (SSE latency). The forked `bootstrap` module is compiled but **not run** — its `/bootstrap` + `/snapshot` endpoints are ursula-specific and not part of the Durable Streams protocol, so it isn't a faithful DS comparison. Catch-up/replay is a Track-2 protocol-faithful workload.
- **Matched durability:** both servers fsync to local disk and offload sealed/cold data to the same MinIO instance. ursula uses `[raft.wal] backend = "disk"` + empty `[raft.peers]` (single-voter Raft, `node_id = 1`); durable-streams uses default fsync. Both group-commit fsyncs — disclose this.
- **ds-bench:** edition `2024`, Rust stable ≥ `1.85`; crate/bin name `ds-bench`; derived from `ursula-bench` (Apache-2.0) — carry the upstream LICENSE + an attribution note.
- **durable-streams server:** binary `durable-streams-server`; build `--features tier`; edition 2021, MSRV 1.75; in Docker use `--http-engine raw` (sendfile, seccomp-safe) and bind `--host 0.0.0.0`; **never `--http-engine uring`** under Docker. S3 creds via env `DS_S3_ACCESS_KEY_ID` / `DS_S3_SECRET_ACCESS_KEY`.
- **ursula:** pinned commit `0b2d0dabf0a6544b909823e0d1d1149b98274e25` (`v0.1.5-3-g0b2d0da`), as a git submodule at `vendor/ursula`; build via ursula's own `Dockerfile` (rust 1.96-bookworm); run `ursula --config ursula.toml --preset standard`.
- **MinIO:** credentials `minioadmin` / `minioadmin`, S3 endpoint `http://minio:9000` (inside compose), region `us-east-1`, path-style addressing, plain HTTP allowed.
- **DS offset tokens are not integers:** wire form `"{:016}_{:016}"`; `?offset=` accepts `-1` (start), `now` (tail), or that 33-char token. Response headers `Stream-Next-Offset` / `Stream-Up-To-Date` / `Stream-Closed` are lowercase on the wire.
- **Ports:** MinIO `9000` (S3) + `9001` (console); durable-streams `4438`; ursula `4437`.
- **DRY, YAGNI, TDD, frequent commits.** Ported code is copied verbatim from the submodule; this plan shows the authored files and the single packaging modification in full.

---

## File Structure

```
ds-rust-bench/
├── .gitignore
├── .gitmodules                       # Task 1
├── vendor/ursula/                    # Task 1 — submodule @ pinned SHA (source of ursula + ursula-bench, Apache-2.0)
├── LICENSE                           # Task 1 — Apache-2.0 (ds-bench derives from ursula-bench)
├── ds-bench/                         # Tasks 2-3 — our workload client (verbatim fork)
│   ├── Cargo.toml                    # Task 2 — standalone, edition 2024, pinned deps
│   ├── rust-toolchain.toml           # Task 2 — stable
│   ├── ATTRIBUTION.md                # Task 2 — derived-from-ursula-bench note
│   └── src/
│       ├── main.rs                   # Task 2 — only change: observability init -> tracing-subscriber
│       ├── backend.rs                # copied verbatim
│       ├── common.rs                 # copied verbatim
│       ├── multi_stream.rs           # copied verbatim (RUN in Track 1)
│       ├── fanout.rs                 # copied verbatim (RUN in Track 1)
│       └── bootstrap.rs              # copied verbatim (compiled, NOT run in Track 1)
├── dockerfiles/
│   ├── durable-streams.Dockerfile    # Task 4
│   └── ds-bench.Dockerfile           # Task 8
├── config/
│   └── ursula.toml                   # Task 5 — single-node disk WAL + s3 cold
├── docker-compose.yml                # Tasks 6-8
├── scripts/
│   ├── smoke-durable.sh              # Task 3 — local smoke of both workloads
│   └── render-results.py             # Task 10
├── run-bench.sh                      # Task 9 — boot minio + one server, run workloads, collect JSON
├── results/                          # JSON + rendered tables (gitignored except .gitkeep)
│   └── .gitkeep
└── README.md                         # Task 11
```

---

### Task 1: Repo scaffold + pinned ursula submodule + license

**Files:**
- Create: `.gitignore`, `LICENSE`, `results/.gitkeep`
- Create (submodule): `vendor/ursula` (+ `.gitmodules`)

**Interfaces:**
- Produces: `vendor/ursula/crates/ursula-bench/src/*` (source to fork in Task 2); `vendor/ursula/Dockerfile` and `vendor/ursula/charts/ursula` (used in Task 5).

- [ ] **Step 1: Add ursula as a pinned submodule**

```bash
cd /Users/vbalegas/workspace/ds-rust-bench
git submodule add https://github.com/tonbo-io/ursula vendor/ursula
git -C vendor/ursula checkout 0b2d0dabf0a6544b909823e0d1d1149b98274e25
git add .gitmodules vendor/ursula
```

- [ ] **Step 2: Verify the submodule is at the pinned SHA**

Run: `git -C vendor/ursula rev-parse HEAD`
Expected: `0b2d0dabf0a6544b909823e0d1d1149b98274e25`

- [ ] **Step 3: Write `.gitignore`**

```gitignore
/target
**/target
results/*
!results/.gitkeep
*.log
.DS_Store
```

- [ ] **Step 4: Add the Apache-2.0 LICENSE and the results placeholder**

```bash
cp vendor/ursula/LICENSE LICENSE
touch results/.gitkeep
```

- [ ] **Step 5: Verify the license copied**

Run: `head -1 LICENSE`
Expected: a line containing `Apache License`

- [ ] **Step 6: Commit**

```bash
git add .gitignore LICENSE results/.gitkeep
git commit -m "chore: scaffold repo + pin ursula submodule @ 0b2d0da"
```

---

### Task 2: ds-bench standalone crate (verbatim fork)

Fork `ursula-bench` into a standalone crate. Copy the source verbatim; the only edits are packaging (`Cargo.toml`, toolchain pin, attribution) and swapping the single `ursula-observability::init` call.

**Files:**
- Create: `ds-bench/Cargo.toml`, `ds-bench/rust-toolchain.toml`, `ds-bench/ATTRIBUTION.md`
- Create (copied verbatim): `ds-bench/src/{main.rs,backend.rs,common.rs,multi_stream.rs,fanout.rs,bootstrap.rs}`
- Modify: `ds-bench/src/main.rs` (observability init only)

**Interfaces:**
- Produces: a `ds-bench` binary with subcommands `multi-stream`, `fan-out`, `bootstrap`, each accepting `--target`, `--api-style {ursula|durable|s2}`, and workload-specific flags. Track 1 invokes only `multi-stream` and `fan-out`.

- [ ] **Step 1: Copy the ursula-bench source verbatim**

```bash
cd /Users/vbalegas/workspace/ds-rust-bench
mkdir -p ds-bench/src
cp vendor/ursula/crates/ursula-bench/src/*.rs ds-bench/src/
ls ds-bench/src
```
Expected files: `backend.rs bootstrap.rs common.rs fanout.rs main.rs multi_stream.rs`

- [ ] **Step 2: Write `ds-bench/Cargo.toml` (standalone, pinned deps)**

```toml
[package]
name = "ds-bench"
version = "0.1.0"
edition = "2024"
license = "Apache-2.0"
description = "Workload benchmark client for Durable Streams servers (durable-streams, ursula). Verbatim fork of ursula-bench."

[[bin]]
name = "ds-bench"
path = "src/main.rs"

[dependencies]
anyhow = "1"
bytes = "1.7"
clap = { version = "4", features = ["derive"] }
futures = "0.3"
hdrhistogram = "7"
reqwest = { version = "0.12", default-features = false, features = ["rustls-tls", "stream", "json"] }
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
tokio = { version = "1.39", features = ["full"] }
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }

[lints.clippy]
wildcard_imports = "deny"
```

(`rand` and `tokio-stream` are intentionally dropped — neither is used in the source. `ursula-observability` is replaced by `tracing-subscriber` in Step 4.)

- [ ] **Step 3: Pin the toolchain**

`ds-bench/rust-toolchain.toml`:
```toml
[toolchain]
channel = "stable"
```

- [ ] **Step 4: Swap the observability init in `ds-bench/src/main.rs` (the only logic edit)**

The original is:
```rust
    let _telemetry =
        ursula_observability::init(ursula_observability::InitOptions::new("ursula-bench"));
```
Replace with:
```rust
    tracing_subscriber::fmt()
        .with_target(true)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();
```
Verify with `grep -rn ursula_observability ds-bench/src` → no matches.

- [ ] **Step 5: Write the attribution note**

`ds-bench/ATTRIBUTION.md`:
```markdown
# Attribution

`ds-bench` is a verbatim fork of `ursula-bench`, part of tonbo-io/ursula
(https://github.com/tonbo-io/ursula), commit
0b2d0dabf0a6544b909823e0d1d1149b98274e25, licensed under Apache-2.0. The three
workloads (multi-stream, fan-out, bootstrap), their HDR-histogram latency
methodology, and the multi-backend API-style abstraction originate there.

Local changes are packaging only: standalone crate layout, pinned dependency
versions, removal of the unused `rand`/`tokio-stream` deps, and replacing the single
`ursula-observability::init` call with `tracing-subscriber`. No workload logic or
measurement methodology has been modified. (Track 1 runs only multi-stream and
fan-out; the bootstrap module is compiled but not run, because its /bootstrap and
/snapshot endpoints are not part of the Durable Streams protocol.)
```

- [ ] **Step 6: Build the crate (the test for this task)**

Run: `cd ds-bench && cargo build --release`
Expected: compiles with no errors (unused-code warnings for `bootstrap` are acceptable). If it fails on `ursula_observability`, re-check Step 4.

- [ ] **Step 7: Verify the CLI surface**

Run: `./target/release/ds-bench --help`
Expected: lists `multi-stream`, `fan-out`, `bootstrap`.
Run: `./target/release/ds-bench fan-out --help`
Expected: shows `--target`, `--api-style`, `--subscribers`, `--writer-rate`, `--duration-secs`, etc.

- [ ] **Step 8: Commit**

```bash
cd /Users/vbalegas/workspace/ds-rust-bench
git add ds-bench
git commit -m "feat(ds-bench): verbatim fork of ursula-bench as standalone crate"
```

---

### Task 3: End-to-end smoke of both workloads vs a local durable-streams server

Prove ds-bench drives durable-streams for `multi-stream` and `fan-out`, emitting valid JSON with real successes. This is the gate confirming the `durable` backend mapping (writes + SSE) works against the server.

**Files:**
- Create: `scripts/smoke-durable.sh`

**Interfaces:**
- Consumes: the `ds-bench` binary (Task 2), a built `durable-streams-server`.

- [ ] **Step 1: Build the durable-streams server binary (slow — LTO release)**

```bash
( cd /Users/vbalegas/workspace/durable-streams/packages/server-rust && cargo build --release --features tier )
ls /Users/vbalegas/workspace/durable-streams/packages/server-rust/target/release/durable-streams-server
```
Expected: the binary exists.

- [ ] **Step 2: Write `scripts/smoke-durable.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
# Usage: DS_SERVER_BIN=/path/to/durable-streams-server scripts/smoke-durable.sh
DS_BIN="${DS_SERVER_BIN:?set DS_SERVER_BIN to the durable-streams-server binary}"
BENCH="$(dirname "$0")/../ds-bench/target/release/ds-bench"
PORT=4470
BASE="http://127.0.0.1:${PORT}"
DATA="$(mktemp -d)"

"$DS_BIN" --host 127.0.0.1 --port "$PORT" --http-engine hyper --data-dir "$DATA" --tier off &
SRV=$!
trap 'kill $SRV 2>/dev/null || true; rm -rf "$DATA"' EXIT
sleep 1

echo "== multi-stream =="
"$BENCH" multi-stream --target "$BASE" --api-style durable \
  --streams 4 --duration-secs 3 --payload-bytes 128 | tee /tmp/ms.json
test "$(jq '.counts.ok' /tmp/ms.json)" -gt 0

echo "== fan-out =="
"$BENCH" fan-out --target "$BASE" --api-style durable \
  --subscribers 8 --writer-rate 50 --duration-secs 5 | tee /tmp/fo.json
test "$(jq '.events_received' /tmp/fo.json)" -gt 0
test "$(jq '.fan_out_latency_ms.count' /tmp/fo.json)" -gt 0

echo "ALL SMOKE CHECKS PASSED"
```

- [ ] **Step 3: Make it executable and run it (the test)**

```bash
chmod +x scripts/smoke-durable.sh
DS_SERVER_BIN=/Users/vbalegas/workspace/durable-streams/packages/server-rust/target/release/durable-streams-server \
  scripts/smoke-durable.sh
```
Expected: ends with `ALL SMOKE CHECKS PASSED`. If `fan-out` reports `events_received == 0`, this is diagnostic (no code change expected): inspect a raw SSE frame with `curl -N "$BASE/v1/stream/doc?offset=now&live=sse"` while appending and confirm `event: data` lines carry the hex payload (text/plain streams are not base64-encoded, so the timestamp parses).

- [ ] **Step 4: Commit**

```bash
git add scripts/smoke-durable.sh
git commit -m "test(ds-bench): end-to-end smoke of multi-stream + fan-out vs durable-streams"
```

---

### Task 4: durable-streams server Dockerfile

**Files:**
- Create: `dockerfiles/durable-streams.Dockerfile`

**Interfaces:**
- Produces: an image whose entrypoint is `durable-streams-server`; built from the sibling `../durable-streams` checkout passed as build context.

- [ ] **Step 1: Write `dockerfiles/durable-streams.Dockerfile`**

```dockerfile
# Build context must be the durable-streams repo root (../durable-streams).
FROM rust:1.83-bookworm AS builder
WORKDIR /src
COPY . .
WORKDIR /src/packages/server-rust
RUN cargo build --release --features tier
RUN cp target/release/durable-streams-server /durable-streams-server

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /durable-streams-server /usr/local/bin/durable-streams-server
EXPOSE 4438
ENTRYPOINT ["durable-streams-server"]
```

- [ ] **Step 2: Build the image (the test)**

Run:
```bash
docker build -f /Users/vbalegas/workspace/ds-rust-bench/dockerfiles/durable-streams.Dockerfile \
  -t ds-bench/durable-streams:dev /Users/vbalegas/workspace/durable-streams
```
Expected: build succeeds, image tagged `ds-bench/durable-streams:dev`. (If the build fails on the Rust version, bump the `rust:1.83-bookworm` tag.)

- [ ] **Step 3: Smoke the image without S3 (tier off)**

```bash
docker run --rm -d --name ds-smoke -p 4438:4438 ds-bench/durable-streams:dev \
  --host 0.0.0.0 --port 4438 --http-engine raw --data-dir /data --tier off
sleep 2
curl -sS -X PUT  http://127.0.0.1:4438/v1/stream/smoke -H 'content-type: application/octet-stream' -i | head -1
curl -sS -X POST http://127.0.0.1:4438/v1/stream/smoke -H 'content-type: application/octet-stream' --data-binary 'hello' -D - -o /dev/null | grep -i stream-next-offset
docker rm -f ds-smoke
```
Expected: PUT returns `201` (or `200`); POST response includes a `stream-next-offset:` header with a `..._...` token.

- [ ] **Step 4: Commit**

```bash
git add dockerfiles/durable-streams.Dockerfile
git commit -m "feat(docker): durable-streams server image (--features tier, raw engine)"
```

---

### Task 5: ursula server image + single-node durable config

ursula ships its own production `Dockerfile`. Reference it via the submodule and supply the matched-durability config.

**Files:**
- Create: `config/ursula.toml`

**Interfaces:**
- Produces: image `ds-bench/ursula:dev`; a config that runs single-node with a disk-fsynced Raft log and S3 cold tier to MinIO.

- [ ] **Step 1: Write `config/ursula.toml`**

```toml
[server]
listen = "0.0.0.0:4437"

[raft]
node_id = 1
# [raft.peers] intentionally omitted -> Topology::SingleNode

[raft.wal]
backend = "disk"
path = "/var/lib/ursula/data"

[storage.cold]
backend = "s3"

[storage.cold.s3]
bucket = "ursula"
endpoint = "http://minio:9000"
region = "us-east-1"
access_key_id = "minioadmin"
secret_access_key = "minioadmin"
```

- [ ] **Step 2: Build ursula's image from the submodule (the test)**

Run:
```bash
docker build -f /Users/vbalegas/workspace/ds-rust-bench/vendor/ursula/Dockerfile \
  -t ds-bench/ursula:dev /Users/vbalegas/workspace/ds-rust-bench/vendor/ursula
docker run --rm ds-bench/ursula:dev --help | head -5
```
Expected: build succeeds; `--help` runs (confirms the entrypoint is the `ursula` binary).

- [ ] **Step 3: Smoke ursula single-node with in-memory cold (no MinIO yet)**

```bash
printf '[server]\nlisten="0.0.0.0:4437"\n[raft]\nnode_id=1\n[raft.wal]\nbackend="disk"\npath="/var/lib/ursula/data"\n[storage.cold]\nbackend="none"\n' > /tmp/ursula-smoke.toml
docker run --rm -d --name ursula-smoke -p 4437:4437 -v /tmp/ursula-smoke.toml:/ursula.toml \
  ds-bench/ursula:dev --config /ursula.toml --preset standard
sleep 3
curl -sS -X PUT  http://127.0.0.1:4437/demo -i | head -1
curl -sS -X PUT  http://127.0.0.1:4437/demo/hello -H 'content-type: application/octet-stream' -i | head -1
curl -sS -X POST http://127.0.0.1:4437/demo/hello -H 'content-type: application/octet-stream' --data-binary 'hi' -i | head -1
curl -sS 'http://127.0.0.1:4437/demo/hello?offset=-1'
docker rm -f ursula-smoke
```
Expected: bucket/stream PUTs return 2xx; the GET returns the appended bytes. (S3 cold tier is exercised in Task 7.)

- [ ] **Step 4: Commit**

```bash
git add config/ursula.toml
git commit -m "feat(ursula): single-node disk-WAL + S3 cold config"
```

---

### Task 6: docker-compose with MinIO + bucket bootstrap

**Files:**
- Create: `docker-compose.yml` (minio + minio-init services)

**Interfaces:**
- Produces: a running MinIO at `minio:9000` inside the compose network, with buckets `durable-streams` and `ursula` pre-created.

- [ ] **Step 1: Write the initial `docker-compose.yml`**

```yaml
name: ds-bench

services:
  minio:
    image: minio/minio:latest
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: minioadmin
    ports:
      - "9000:9000"
      - "9001:9001"
    healthcheck:
      test: ["CMD", "mc", "ready", "local"]
      interval: 3s
      timeout: 5s
      retries: 20

  minio-init:
    image: minio/mc:latest
    depends_on:
      minio:
        condition: service_healthy
    entrypoint: >
      /bin/sh -c "
      mc alias set local http://minio:9000 minioadmin minioadmin &&
      mc mb -p local/durable-streams &&
      mc mb -p local/ursula &&
      echo 'buckets ready'
      "
```

- [ ] **Step 2: Bring up MinIO + init (the test)**

```bash
docker compose up -d minio
docker compose run --rm minio-init
docker compose exec minio mc ls local
```
Expected: `minio-init` prints `buckets ready`; `mc ls local` lists `durable-streams/` and `ursula/`.

- [ ] **Step 3: Commit**

```bash
git add docker-compose.yml
git commit -m "feat(compose): minio + bucket bootstrap"
```

---

### Task 7: Wire servers into compose with S3 offload + verify objects land in MinIO

**Files:**
- Modify: `docker-compose.yml` (add `durable-streams` and `ursula` services)

**Interfaces:**
- Consumes: `dockerfiles/durable-streams.Dockerfile` (Task 4), `ds-bench/ursula:dev` (Task 5), `config/ursula.toml` (Task 5), MinIO (Task 6).
- Produces: services `durable-streams` (`:4438`) and `ursula` (`:4437`) on the compose network, both offloading to MinIO.

- [ ] **Step 1: Add the `durable-streams` service**

Append to `docker-compose.yml` under `services:`:
```yaml
  durable-streams:
    build:
      context: ../durable-streams
      dockerfile: ../ds-rust-bench/dockerfiles/durable-streams.Dockerfile
    depends_on:
      minio:
        condition: service_healthy
    environment:
      DS_S3_ACCESS_KEY_ID: minioadmin
      DS_S3_SECRET_ACCESS_KEY: minioadmin
    command:
      - --host=0.0.0.0
      - --port=4438
      - --data-dir=/data
      - --http-engine=raw
      - --tier=s3
      - --tier-endpoint=http://minio:9000
      - --tier-region=us-east-1
      - --tier-bucket=durable-streams
      - --tier-allow-http
      - --tier-segment-bytes=1048576
    ports:
      - "4438:4438"
```
(`--tier-segment-bytes=1048576` = 1 MiB so a short smoke run seals + offloads a segment quickly. The default is 8 MiB; the measured runs in Task 9 use the default.)

- [ ] **Step 2: Add the `ursula` service**

```yaml
  ursula:
    image: ds-bench/ursula:dev
    depends_on:
      minio:
        condition: service_healthy
    volumes:
      - ./config/ursula.toml:/ursula.toml:ro
    command: ["--config", "/ursula.toml", "--preset", "standard"]
    ports:
      - "4437:4437"
```

- [ ] **Step 3: Verify durable-streams offloads to MinIO (the test)**

```bash
docker compose up -d minio
docker compose run --rm minio-init
docker compose up -d --build durable-streams
sleep 3
S=http://127.0.0.1:4438/v1/stream/offload-test
curl -sS -X PUT "$S" -H 'content-type: application/octet-stream' >/dev/null
head -c 2000000 /dev/urandom | curl -sS -X POST "$S" -H 'content-type: application/octet-stream' --data-binary @- >/dev/null
sleep 3
docker compose exec minio mc ls --recursive local/durable-streams
```
Expected: `mc ls` lists one or more objects under `local/durable-streams/` (the sealed segment(s)).

- [ ] **Step 4: Verify ursula offloads to MinIO**

```bash
docker compose up -d ursula
sleep 4
curl -sS -X PUT http://127.0.0.1:4437/demo >/dev/null
curl -sS -X PUT http://127.0.0.1:4437/demo/big -H 'content-type: application/octet-stream' >/dev/null
head -c 2000000 /dev/urandom | curl -sS -X POST http://127.0.0.1:4437/demo/big -H 'content-type: application/octet-stream' --data-binary @- >/dev/null
sleep 6   # ursula cold flush_interval defaults ~1s; allow a flush cycle
docker compose exec minio mc ls --recursive local/ursula
docker compose down
```
Expected: `mc ls` lists object(s) under `local/ursula/`. (If empty, raise the appended volume above ursula's `max_hot_size_per_group` to force a cold flush, then re-check after `flush_interval`.)

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml
git commit -m "feat(compose): durable-streams + ursula services with MinIO offload"
```

---

### Task 8: ds-bench image + bench runner service

**Files:**
- Create: `dockerfiles/ds-bench.Dockerfile`
- Modify: `docker-compose.yml` (add `bench` service)

**Interfaces:**
- Produces: image `ds-bench/ds-bench:dev`; a `bench` service that runs `ds-bench` on the compose network (reaching `durable-streams:4438` / `ursula:4437`) and writes JSON to a mounted `results/`.

- [ ] **Step 1: Write `dockerfiles/ds-bench.Dockerfile`**

```dockerfile
# Build context is the ds-bench/ crate directory.
# ds-bench is edition 2024 -> needs Rust >= 1.85.
FROM rust:1.85-bookworm AS builder
WORKDIR /src
COPY . .
RUN cargo build --release
RUN cp target/release/ds-bench /ds-bench

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /ds-bench /usr/local/bin/ds-bench
ENTRYPOINT ["ds-bench"]
```

- [ ] **Step 2: Add the `bench` service to `docker-compose.yml`**

```yaml
  bench:
    build:
      context: ./ds-bench
      dockerfile: ../dockerfiles/ds-bench.Dockerfile
    image: ds-bench/ds-bench:dev
    profiles: ["bench"]   # only runs when explicitly invoked
    volumes:
      - ./results:/results
    # command is supplied at run time by run-bench.sh
```

- [ ] **Step 3: Build the bench image + run a containerized smoke against durable-streams (the test)**

```bash
docker compose up -d minio && docker compose run --rm minio-init
docker compose up -d --build durable-streams
docker compose build bench
docker compose run --rm bench multi-stream \
  --target http://durable-streams:4438 --api-style durable \
  --streams 4 --duration-secs 3 --payload-bytes 128 > results/smoke-ms.json
jq '.counts.ok' results/smoke-ms.json
docker compose down
```
Expected: `results/smoke-ms.json` contains `counts.ok > 0`.

- [ ] **Step 4: Commit**

```bash
git add dockerfiles/ds-bench.Dockerfile docker-compose.yml
git commit -m "feat(compose): ds-bench image + bench runner service"
```

---

### Task 9: Orchestration — run one server, both workloads, collect JSON

**Files:**
- Create: `run-bench.sh`

**Interfaces:**
- Consumes: the full compose stack (Tasks 6-8).
- Produces: `results/<system>-<workload>.json` for `system ∈ {durable, ursula}` and the two workloads, with identical workload parameters across systems.

- [ ] **Step 1: Write `run-bench.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
# Usage: ./run-bench.sh <durable|ursula>
SYS="${1:?usage: run-bench.sh <durable|ursula>}"
case "$SYS" in
  durable) SVC=durable-streams; TARGET=http://durable-streams:4438; STYLE=durable ;;
  ursula)  SVC=ursula;          TARGET=http://ursula:4437;          STYLE=ursula  ;;
  *) echo "unknown system: $SYS" >&2; exit 2 ;;
esac

# Identical workload parameters across systems (fairness).
STREAMS=200; DURATION=30; PAYLOAD=256
SUBSCRIBERS=500; WRITER_RATE=50

mkdir -p results
docker compose up -d minio
docker compose run --rm minio-init
echo "== starting $SVC (only server running) =="
docker compose up -d --build "$SVC"
sleep 5

run() { docker compose run --rm bench "$@"; }

echo "== multi-stream =="
run multi-stream --target "$TARGET" --api-style "$STYLE" \
  --streams "$STREAMS" --duration-secs "$DURATION" --payload-bytes "$PAYLOAD" \
  > "results/${SYS}-multi-stream.json"

echo "== fan-out =="
run fan-out --target "$TARGET" --api-style "$STYLE" \
  --subscribers "$SUBSCRIBERS" --writer-rate "$WRITER_RATE" --duration-secs "$DURATION" \
  --payload-bytes "$PAYLOAD" > "results/${SYS}-fanout.json"

echo "== stopping $SVC =="
docker compose stop "$SVC"
echo "results written to results/${SYS}-*.json"
```

- [ ] **Step 2: Run it for durable-streams (the test)**

```bash
chmod +x run-bench.sh
./run-bench.sh durable
jq '.scenario, .counts.ok' results/durable-multi-stream.json
jq '.scenario, .events_received' results/durable-fanout.json
```
Expected: two JSON files exist; multi-stream has `counts.ok > 0`, fan-out has `events_received > 0`.

- [ ] **Step 3: Run it for ursula**

```bash
./run-bench.sh ursula
jq '.scenario, .counts.ok' results/ursula-multi-stream.json
jq '.scenario, .events_received' results/ursula-fanout.json
```
Expected: two `ursula-*.json` files with successful counts. (Only ursula runs during its measurement; durable-streams was stopped.)

- [ ] **Step 4: Commit**

```bash
git add run-bench.sh
git commit -m "feat: orchestration to run both workloads against one server at a time"
```

---

### Task 10: Results renderer → markdown comparison table

**Files:**
- Create: `scripts/render-results.py`

**Interfaces:**
- Consumes: `results/{durable,ursula}-{multi-stream,fanout}.json`.
- Produces: `results/comparison.md` with per-workload comparison tables.

- [ ] **Step 1: Write `scripts/render-results.py`**

```python
#!/usr/bin/env python3
"""Render results/*.json into a markdown comparison table. Usage: render-results.py [results_dir]"""
import json, sys, pathlib

RESULTS = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "results")
SYSTEMS = ["durable", "ursula"]

def load(system, workload):
    p = RESULTS / f"{system}-{workload}.json"
    return json.loads(p.read_text()) if p.exists() else None

def lat(d):
    if not d: return ("-",) * 4
    l = d.get("latency_ms") or d.get("fan_out_latency_ms") or {}
    return (f"{l.get('p50_ms',0):.2f}", f"{l.get('p90_ms',0):.2f}",
            f"{l.get('p99_ms',0):.2f}", f"{l.get('p999_ms',0):.2f}")

def row(label, fn):
    return "| " + label + " | " + " | ".join(fn(s) for s in SYSTEMS) + " |"

out = ["# Single-node comparison: durable-streams vs ursula", ""]
hdr = "| metric | " + " | ".join(SYSTEMS) + " |"
sep = "|" + "---|" * (len(SYSTEMS) + 1)

ms = {s: load(s, "multi-stream") for s in SYSTEMS}
out += ["## multi-stream (write throughput)", "", hdr, sep,
        row("aggregate ops/s", lambda s: f"{(ms[s] or {}).get('aggregate_ops_per_sec',0):.0f}"),
        row("p50/p90/p99/p999 ms", lambda s: " / ".join(lat(ms[s]))),
        row("ok / backpressure / err",
            lambda s: f"{(ms[s] or {}).get('counts',{}).get('ok',0)} / "
                      f"{(ms[s] or {}).get('counts',{}).get('backpressure',0)} / "
                      f"{(ms[s] or {}).get('counts',{}).get('other_err',0)}"), ""]

fo = {s: load(s, "fanout") for s in SYSTEMS}
out += ["## fan-out (SSE end-to-end latency)", "", hdr, sep,
        row("events received", lambda s: f"{(fo[s] or {}).get('events_received',0)}"),
        row("p50/p90/p99/p999 ms", lambda s: " / ".join(lat(fo[s]))), ""]

(RESULTS / "comparison.md").write_text("\n".join(out))
print("\n".join(out))
```

- [ ] **Step 2: Run it against the results from Task 9 (the test)**

```bash
chmod +x scripts/render-results.py
python3 scripts/render-results.py results
test -f results/comparison.md && head -20 results/comparison.md
```
Expected: prints a markdown doc with two sections; `results/comparison.md` exists with both `durable` and `ursula` columns populated.

- [ ] **Step 3: Commit**

```bash
git add scripts/render-results.py
git commit -m "feat: render results JSON into markdown comparison table"
```

---

### Task 11: README with methodology + fairness disclosure

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write `README.md`**

````markdown
# ds-rust-bench — Track 1: single-node comparison

Reproducible single-node benchmark of **durable-streams** (Rust) vs **ursula**,
under matched durability, driven by `ds-bench` — a **verbatim fork of ursula's own
`ursula-bench`**. See the design spec at
`docs/superpowers/specs/2026-06-17-single-node-bench-design.md`.

## Quick start

```bash
git submodule update --init --recursive        # pulls vendor/ursula @ pinned SHA
./run-bench.sh durable                          # both workloads vs durable-streams
./run-bench.sh ursula                           # then vs ursula (one server at a time)
python3 scripts/render-results.py results       # -> results/comparison.md
```

## What is measured

`ds-bench` (a verbatim fork of `ursula-bench`, Apache-2.0 — packaging changes only)
drives two workloads, each emitting HDR-histogram latency + ops/s JSON:

- **multi-stream** — N concurrent streams, one writer each (write throughput + latency).
- **fan-out** — one stream, many SSE subscribers (end-to-end per-event latency).

Catch-up/replay is intentionally **not** included: ursula-bench's `bootstrap` workload
is built on ursula's `/bootstrap` and `/snapshot/{offset}` endpoints, which are **not
part of the Durable Streams protocol** (no such routes in `PROTOCOL.md` or the DS
server). A protocol-faithful catch-up-read workload is planned for Track 2.

## Fairness — what is equal, and what is not

- **Equal:** single node each; **ursula's own benchmark client, unmodified** (only
  packaging changed); identical workload parameters (see `run-bench.sh`); both servers
  fsync to local disk; both offload sealed/cold data to the same MinIO. Only one
  server runs during its own measurement.
- **Matched durability:** ursula runs a single-voter Raft group with
  `[raft.wal] backend = "disk"` (fsync per commit); durable-streams fsyncs per append.
  **Both group-commit fsyncs** (ursula: 200µs/1024-record window; durable-streams:
  coalesced across concurrent writers), so this is apples-to-apples for concurrent
  writes; under serial load both approach one fsync per append.
- **Not equal / disclosed:** single-node deliberately strips ursula's Raft
  *replication*, its headline feature — we benchmark single-node only because
  durable-streams has no multi-node yet. We do **not** reuse ursula's published
  numbers (3-node quorum, a `perf_compare` client not in the repo). All numbers here
  are generated by `ds-bench` on the same machine.

## Configuration

- durable-streams: `--http-engine raw`, `--tier s3` → MinIO (`dockerfiles/durable-streams.Dockerfile`, `docker-compose.yml`).
- ursula: `config/ursula.toml` (`ds-bench/ursula:dev`, built from `vendor/ursula` @ `0b2d0da`).
- MinIO: `minioadmin`/`minioadmin`, buckets `durable-streams` and `ursula`.

## Caveats

- `io_uring` is not used (unreliable under Docker); durable-streams runs the `raw`
  engine. A real Linux host can enable `uring` later (Track 2 / Phase 2).
````

- [ ] **Step 2: Verify the quick-start commands match the actual scripts (the test)**

```bash
grep -q 'run-bench.sh durable' README.md && grep -q 'render-results.py' README.md && echo "README references valid"
test -f run-bench.sh && test -f scripts/render-results.py && echo "referenced files exist"
```
Expected: both lines print their confirmation.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README with methodology + fairness disclosure"
```

---

## Self-Review

**Spec coverage:**
- docker-compose runtime, Linux containers → Tasks 4-8. ✓
- MinIO local S3 + bucket bootstrap → Task 6. ✓
- durable-streams `--features tier`, raw engine, `--tier s3` → Tasks 4, 7. ✓
- ursula single-node disk-WAL + S3 cold (resolved config) → Task 5. ✓
- ds-bench v0 as a **verbatim fork** (packaging only), two workloads → Tasks 2-3. ✓
- `durable` api-style maps to DS (resolved — no variant needed) → Task 3 smoke. ✓
- Catch-up/replay deferred because `/bootstrap` + `/snapshot` aren't in the DS protocol → README + ATTRIBUTION (Tasks 2, 11). ✓
- Fairness controls (one server at a time, identical params, unmodified client, group-commit disclosure) → Task 9 (identical params, single server) + Task 11 (disclosure). ✓
- Results rendering + comparison table → Task 10. ✓
- Success criteria (compose brings up MinIO + a server; ds-bench runs both workloads; offload verified; rendered table) → Tasks 7 (offload), 9 (workloads), 10 (table). ✓

**Deferred spec open item (not a gap):** CPU/memory pinning is not enforced — add `deploy.resources` / `--cpus` to the compose services if runs prove noisy; called out here so it isn't mistaken for coverage.

**Placeholder scan:** the only conditional steps are diagnostics (Task 3 SSE check; Task 7 flush note) attached to concrete assertions — no "TODO"/"implement later". ds-bench has zero workload-logic changes.

**Type consistency:** result-struct field names used by the renderer (`aggregate_ops_per_sec`, `counts.{ok,backpressure,other_err}`, `events_received`, `fan_out_latency_ms`, `latency_ms`) match the structs in the upstream source. CLI subcommands are `multi-stream` and `fan-out` (clap kebab-cases the `FanOut` variant) — matched in the smoke script, `run-bench.sh`, and the renderer's `fanout` result filename (the scenario writes `${SYS}-fanout.json`).

**Note on builder Rust versions:** the durable-streams Dockerfile (Task 4) pins `rust:1.83-bookworm` (MSRV 1.75; bump if deps require newer). The ds-bench Dockerfile (Task 8) pins `rust:1.85-bookworm` (edition 2024 needs ≥1.85).
