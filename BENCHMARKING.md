# DS-rust benchmark suite — reproducible runbook

A single procedure that runs the **full comparison matrix** against the durable-streams Rust server and produces **one complete report**. The *same commands* run on a **local kind cluster** (fast dev loop, free) or a **remote GKE cluster** (measurement-grade, multi-node) — selected by one variable, `DS_TARGET` — so results from two clusters compare side-by-side.

> Intended use: one agent iterates on the server locally (`DS_TARGET=local`) while another runs the same suite on cloud (`DS_TARGET=remote`); diff the two reports.

---

## 0. Concepts

One runner — **`scripts/gke-bench.sh`** — runs the whole comparison: a grid of SYSTEMS × WORKLOADS, each cell a fresh deploy + warm-up + settle + measure, written to `results/bench/bench-<ts>/summary.tsv`.

| Workload | Sweep | Systems / configs | Reps | Metric |
|---|---|---|---|---|
| **write** (multi-stream) | 1k / 10k / 100k streams | durable `strict`·`strict-iouring`·`wal`·`fast`, ursula `memory`, s2 | 2 | ops/s + p99 |
| **sse** (multi-fanout) | 1 stream × {1,10,100,1000} subs (Ursula-style) | durable `fast`, ursula `memory`, s2 | 1 | delivery p99 |
| **replay** (catch-up) | 1000 clients × 200 events | durable `fast`, ursula `memory` (s2 excluded) | 2 | p99 |
| **sustained** | 10 / 50 / 100 / 150 streams | durable only | 2 | ops/s + p99 + RSS drift |

Durability mode only affects the **write** path, so the read workloads (sse, replay) run a single durable config (`fast`). Clients are provisioned well above the bottleneck within the cluster's pool: the write/replay fleet is many light pods (`FLEET_CPU`, `PER_POD`), and SSE runs on **one well-provisioned pod** (`SSE_FLEET_CPU` ≈ a full client node) so the writer + subscribers share one wall clock → clean delivery p99, no cross-pod skew.

The engine (deploy server, run client fleet, merge HDR results, calibrate/pin, sidecar metrics) is shared in **`scripts/lib-bench.sh`**; target selection (context, image refs, node selectors) is in **`scripts/target-env.sh`**.

### `DS_TARGET`

```bash
export DS_TARGET=local      # kind cluster, locally-built images, single node (default)
export DS_TARGET=remote     # GKE, Artifact Registry images, role=server/client pools
```

Optional: `KIND_CLUSTER` (default `ds-bench`); for remote, `PROJECT`/`ZONE`/`CLUSTER` (defaults: gcloud project / `europe-west1-b` / `ds-bench`).

### Where things land

- Per-cell data: `results/bench/bench-<ts>/<cell>-r<rep>/rep1/...` (`merged.json` = merged HDR/throughput, `samples.csv` = server RSS/CPU, `verdict.txt`).
- Consolidated: `results/bench/bench-<ts>/summary.tsv` (one row per cell × rep).

---

## 1. Prerequisites

**Local (`DS_TARGET=local`):** Docker running, `kind`, `kubectl`, `envsubst` (gettext), `python3`. A clone of the server at `../durable-streams`. Nothing in the cloud, no billing.

**Remote (`DS_TARGET=remote`):** `gcloud` authenticated with access to the project, plus `kubectl`/`envsubst`/`python3`. Images build via Cloud Build (amd64).

> Local builds are **native arch** (`docker build` + `kind load`) — fast, no QEMU, no registry. Remote builds go through Cloud Build → Artifact Registry.

---

## 2. Cluster up

```bash
export DS_TARGET=local        # or remote
scripts/cluster-up.sh
```

Creates the cluster (kind single node / GKE server+clients pools), the `ds-bench` namespace, the `metrics-poller` ConfigMap, and MinIO (the object tier + the HDR-merge store). Idempotent. **Run this before building images** — for local, `kind load` (next step) needs the cluster to already exist.

## 3. Build images

```bash
scripts/build-images.sh
```

Builds `ds-bench:dev` (workload client) and `durable-streams:dev` (server, from the **current `../durable-streams` checkout**, with `FEATURES=tier,strict-uring` so the `durable:strict-iouring` variant exercises the io_uring fsync executor) and loads them into the cluster. Iterating on the server? `git -C ../durable-streams checkout <branch>` then re-run this — that is the inner dev loop.

## 4. Run the matrix

One command for local and remote — `scripts/gke-bench.sh` runs the full SYSTEMS × WORKLOADS grid (§0), deploying each cell fresh, warming up + settling, measuring, and appending to `results/bench/bench-<ts>/summary.tsv`.

```bash
# full matrix (local)
DS_TARGET=local CLUSTER=ds-bench scripts/gke-bench.sh

# remote (GKE)
DS_TARGET=remote PROJECT=<gcp> ZONE=<zone> CLUSTER=<cluster> scripts/gke-bench.sh

# quick smoke — one system × one workload × one rep
SYSTEMS='durable:wal' WORKLOADS='write' WRITE_CARDS='1000' REPEATS=1 \
  DS_TARGET=local CLUSTER=ds-bench scripts/gke-bench.sh
```

**Knobs** (override any): `SYSTEMS`, `WORKLOADS` (`write sse replay sustained`), `WRITE_CARDS`, `SSE_STREAMS`/`SSE_TOTAL_SUBS`, `REPLAY_CONF`, `SUSTAINED_CARDS`/`SUSTAINED_RATE`/`SUSTAINED_DURATION`, `REPEATS` (default 2), `WARMUP_SECS`/`SETTLE_SECS`/`DURATION`, `FLEET_CPU` (write fleet), `SSE_FLEET_CPU`, `PER_POD` (target streams/pod), `WAL_SHARDS`, `TAIL_CACHE_BYTES`. See the full Configuration reference below.

> **Calibrate / `verdict.txt`.** Write cells run client-unbound at a pinned pod count (calibrate-then-pin, below). A cell is `server_bound` (trustworthy ceiling) only if the server consumed ≥90% of its CPU budget; otherwise `client_capped` (a lower bound — add `PER_POD`/pods). SSE runs on one well-provisioned pod by design (delivery-latency test).

## 5. Read the results

Each run writes `results/bench/bench-<ts>/summary.tsv` — one row per `(system, variant, workload, params, pods, rep)` with throughput/ev-s, p99, and cpu_pct. Aggregate across reps (median + CV%) with the shared helpers in `scripts/render_common.py` (`load_rep` / `aggregate_cell`), which read each cell's `rep1/{merged.json,samples.csv,verdict.txt}`.

## 6. Report

Render the one consolidated table from `summary.tsv` (§5) and lead with the run context so it's reproducible:

- `DS_TARGET`, cluster shape, server commit (`git -C ../durable-streams rev-parse --short HEAD`), date, the systems/workloads run.
- Headlines: write ops/s + p99 by cardinality; SSE delivery p99 by subscriber count; replay p99.
- Honesty notes: cells marked `client_capped` are lower bounds; the object tier is in-cluster MinIO (not cloud S3); `cpu_pct` is durable-only; reps (write/replay 2, SSE 1).

Suggested path: `docs/combined-report-<target>-<date>.md` — produce one per target to diff local vs cloud.

### Known server limits (now fixed — confirm they stay fixed)

Two limits bounded earlier runs; both are fixed in the server and worth re-confirming:

1. **fd ulimit** — the server stalled at exactly ~1024 concurrent connections (default `RLIMIT_NOFILE`). Fixed: the server raises NOFILE at startup (`raise_nofile_limit`) + the accept loop backs off on `EMFILE`. **Confirm:** drive >1024 conns and verify the server stays up.
2. **stream-creation timeout** — concurrent `PUT /v1/stream` timed out at ~200. Fixed: creation runs off the async worker pool (`spawn_blocking`). **Confirm:** a high-cardinality write cell (N≥200) completes.

## Pod counts & client provisioning

`gke-bench.sh` runs each cell at a **fixed, computed** client pod count (`MODE=calibrate MAX_BUMPS=0` — no headroom bumping):

- **write / replay** — `ceil(N / PER_POD)` light fleet pods (`FLEET_CPU` each, default 0.5), capped at `MAX_FLEET_PODS` (default 200, floor 2). Many light pods keep the load generator well above the server's needs (client-unbound). Lower `PER_POD` / raise `MAX_FLEET_PODS` to add client pods, bounded by the cluster's `clients` node pool.
- **sse** — **one** well-provisioned pod at `SSE_FLEET_CPU` (≈ a full client node), so writer + subscribers share one wall clock (clean delivery p99).

The pinned count + the running image digest land in `calibration/pins.json` (keyed by server-image-digest + machine + cpu/mem). Each cell's `verdict.txt` records whether the server was the bottleneck (`server_bound`, a trustworthy ceiling) or the client capped it (`client_capped`, a lower bound — add client pods).

## 7. Tear down

```bash
scripts/cluster-down.sh           # remote: pass the same ZONE you created with
```

Local: `kind delete cluster`. **Remote: deletes the GKE cluster, verifies it is gone (no billing), unsets the context — always run this after a cloud run.**

---

## Troubleshooting (practical notes)

- **GKE zone out of capacity** (`does not have enough resources available to fulfill request: <zone>`): retry in a SIBLING zone of the same region (so the `benchmarking` subnetwork still applies): `ZONE=europe-west1-d scripts/cluster-up.sh`. The kubectl context follows the zone (`gke_<project>_<zone>_ds-bench`), so pass the **same `ZONE`** to every later phase/render/teardown command.
- **Local Docker build wedges or crawls**: Docker Desktop under disk pressure stalls builds (the daemon stops accepting new work — even `docker run alpine` hangs). Free it with `docker builder prune -af && docker image prune -af` (or full `docker system prune -af --volumes`), then re-run `build-images.sh`. Native arm64 build is ~10 min the first time.
- **Every cell is `client_capped`**: the client fleet — not the server — is the bottleneck. Lower `PER_POD` (more pods per cardinality) and/or raise `MAX_FLEET_PODS` until cells go `server_bound` (the trustworthy ceiling), bounded by the `clients` node pool.
- **A cell renders `-` / empty**: that cell's fleet errored; the tolerant fleet/coordinator waits keep the rest of the matrix running. Inspect `kubectl --context $KCTX -n ds-bench logs job/bench-fleet`. Usually a server hiccup or a cap set too aggressively.
- **Iterating on the server**: `git -C ../durable-streams checkout <branch>` → re-run `build-images.sh` → re-run the phase. The image is built from the current checkout, so that is the whole inner loop.

---

## Configuration reference

All knobs are environment variables (export before the command); defaults in parentheses. Cross-checked against `scripts/gke-bench.sh`, `scripts/target-env.sh`, and `scripts/cluster-up.sh`.

### Target & cluster — `target-env.sh`, `cluster-up.sh`
| var | default | meaning |
|---|---|---|
| `DS_TARGET` | `local` | `local` (kind) or `remote` (GKE). gke-bench.sh itself defaults to `remote`. |
| `KIND_CLUSTER` | `ds-bench` | local kind cluster name (context `kind-<name>`) |
| `PROJECT` | `vaxine` (or `gcloud config` project) | remote GCP project; part of context `gke_<PROJECT>_<ZONE>_<CLUSTER>` |
| `ZONE` | `europe-west1-b` | remote GKE zone (required by gke-bench.sh for remote) |
| `CLUSTER` | `ds-bench` | remote GKE cluster name (required by gke-bench.sh for remote) |
| `IMG_SERVER` | `durable-streams:dev` (local) / `<REG>/durable-streams:dev` (remote) | server image ref; override to compare distinct server image tags |
| `CLIENT_NODES` | `2` | client node-pool size (remote). More machines = more load-gen capacity, but beyond the server's real bottleneck adding these does nothing. |
| `SERVER_MACHINE` | `kind` (local) / `c4d-standard-16-lssd` (remote) | server node machine type; also a calibration-key component |
| `SERVER_MEM` | `16Gi` | server pod memory limit (cgroup OOM ceiling; drives fan-out subscriber capacity) |
| `LOCAL_SSD_COUNT` | `1` | striped local SSDs for *non-`-lssd`* machine types (e.g. `n2d-standard-8`); `-lssd` machines bundle a fixed Local SSD and ignore this |
| `URSULA_WAL` | `disk` | Ursula Raft WAL backend: `disk` (durable) or `memory` (Ursula's analog of durable's fast/non-durable mode) |

### Matrix dimensions — `gke-bench.sh`
| var | default | meaning |
|---|---|---|
| `SYSTEMS` | `durable:strict durable:strict-iouring durable:wal durable:fast ursula:memory s2:_` | `system:variant` cells, run in order (primary system first) |
| `WORKLOADS` | `write sse replay sustained` | which workloads to run |
| `WRITE_CARDS` | `1000 10000 100000` | stream counts for the write sweep |
| `SSE_STREAMS` | `1` | SSE fan-out streams (M) |
| `SSE_TOTAL_SUBS` | `1 10 100 1000` | SSE total subscribers (T); subs/stream = T/M, cells with T<M skipped |
| `REPLAY_CONF` | `1000:200` | replay `clients:pre_events` for catch-up |
| `SUSTAINED_CARDS` | `10 50 100 150` | sustained stream counts (durable-only sweep) |
| `SUSTAINED_RATE` | `10` | sustained per-stream ops/sec |
| `SUSTAINED_DURATION` | `90` | sustained measurement duration (long, so RSS sidecar captures drift) |
| `REPEATS` | `2` | measured reps per write/replay/sustained cell (reported as mean) |
| `SSE_REPS` | `1` | measured reps per SSE cell (delivery p99 is stable → 1) |
| `WARMUP_SECS` | `10` | uncounted warm-up seconds per cell |
| `SETTLE_SECS` | `5` | idle settle seconds before the measured window |
| `DURATION` | `20` | measured seconds per cell |
| `SERVER_CPUS` | `4` | server CPU budget (cgroup `cpu.max` → tokio workers); first token used |
| `SERVER_MEM` | `16Gi` | server pod memory limit (see also target-env.sh) |

### Fleet / client provisioning — `gke-bench.sh`
| var | default | meaning |
|---|---|---|
| `FLEET_CPU` | `0.5` | per-fleet-pod CPU reservation (write/replay); many light pods keep the client unbound |
| `SSE_FLEET_CPU` | `12` | CPU for the single SSE pod (≈ a full n2d-standard-16 client node) |
| `PER_POD` | `250` | target streams/pod; fleet pods = `ceil(N/PER_POD)` |
| `MAX_FLEET_PODS` | `200` | cap on fleet pods (floor 2) |
| `FLEET_TIMEOUT` | `360` | seconds before a hung fleet is abandoned (tolerant — keeps the matrix going) |
| `COORD_TIMEOUT` | `180` | seconds before a hung coordinator is abandoned |

### Server flags — durable-streams (set per cell by `deploy_system`)
| flag / knob | default | meaning |
|---|---|---|
| `--durability {strict\|wal\|fast}` | per `SYSTEMS` variant | write-path durability mode; `strict-iouring` = `strict` + `--strict-io-uring` |
| `--splice-appends` | on (every durable variant) | zero-copy splice(2) for binary appends; a CPU lever (~½–⅓ append CPU) |
| `WAL_SHARDS` (`--wal-shards`) | `4` (runner) | WAL shard count, passed only for `wal`/`wal-cache` variants. The server's own default when unset is the CPU core count on a fresh data dir. |
| `TAIL_CACHE_BYTES` (`--tail-cache-bytes`) | `65536` (runner, `wal-cache` only) | resident tail-cache cap; passed only for the `wal-cache` variant. The server default is `0` (off) on Linux and `64 KiB` on macOS. |

The cold-tier backend (`--tier {s3\|local}`) is left at the server default (`s3` → in-cluster MinIO) for these cells.

---

## io_uring (Linux) — seccomp requirements

The `durable:strict-iouring` variant runs the server built `--features strict-uring` with `--strict-io-uring` (a shared io_uring ring batching strict-mode `fdatasync`s; it falls back to `spawn_blocking` if io_uring is unavailable). The harness is unchanged — only the io_uring syscalls must be permitted at runtime:

- **Remote (GKE):** the server pod sets `securityContext.seccompProfile.type: Unconfined` (`gke/durable-streams.yaml`) — Docker 25 / containerd's default seccomp blocks `io_uring_setup/enter/register` (moby#46762), and a Pod-Security/CIS policy can impose `RuntimeDefault`; `Unconfined` permits them. Confirmed on our cluster: **GKE Standard** (not Autopilot), **COS** node image, **kernel 6.12** (≥ 6.0 → io_uring *and* `IORING_OP_SEND_ZC` zero-copy-send both work), **no gVisor/sandbox** (gVisor has no io_uring — do not route this pod through it). No other change needed.
- **Local (kind) — works directly, no extra setup** (verified empirically). kind launches its node containers `--privileged` with `seccomp=unconfined apparmor=unconfined`, so the node boundary does NOT block io_uring — the *only* gate is the **pod's** `seccompProfile`, and we already set it to `Unconfined`. Test result: an `Unconfined` pod → `io_uring_setup` returns an fd (PERMITTED); a `RuntimeDefault` pod → EPERM (BLOCKED). Docker Desktop's VM kernel is **6.10** (≥ 6.0), so **io_uring AND `IORING_OP_SEND_ZC` zero-copy-send both work inside kind** — no separate Linux VM and no special kind config required. So the full multi-pod harness runs real io_uring locally. (Outside k8s, `docker run --security-opt seccomp=unconfined …` works too for a single-instance smoke.)
- Unconfined is a superset of permissions → the reference / ursula / s2 images are unaffected.

---

## One-shot (local smoke)

```bash
export DS_TARGET=local
scripts/cluster-up.sh && scripts/build-images.sh
SYSTEMS='durable:wal' WORKLOADS='write' WRITE_CARDS='1000' REPEATS=1 \
  CLUSTER=ds-bench scripts/gke-bench.sh
scripts/cluster-down.sh
```
