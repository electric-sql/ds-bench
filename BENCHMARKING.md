# DS-rust benchmark suite — reproducible runbook

A single procedure that runs the **three benchmark phases** against the
durable-streams Rust server and produces **one complete report**. The *same
commands* run on a **local kind cluster** (fast dev loop, free) or a **remote GKE
cluster** (measurement-grade, multi-node) — selected by one variable,
`DS_TARGET` — so results from two clusters compare side-by-side.

> Intended use: one agent iterates on the server locally (`DS_TARGET=local`)
> while another runs the same suite on cloud (`DS_TARGET=remote`); diff the two
> reports.

---

## 0. Concepts

One runner — **`scripts/gke-bench.sh`** — runs the whole comparison: a grid of
SYSTEMS × WORKLOADS, each cell a fresh deploy + warm-up + settle + measure, written to
`results/bench/bench-<ts>/summary.tsv`.

| Workload | Sweep | Systems / configs | Reps | Metric |
|---|---|---|---|---|
| **write** (multi-stream) | 1k / 10k / 100k streams | durable `strict`·`strict-iouring`·`wal`·`fast`, ursula `memory`, s2 | 2 | ops/s + p99 |
| **sse** (multi-fanout) | 1 stream × {1,10,100,1000} subs (Ursula-style) | durable `fast`, ursula `memory`, s2 | 1 | delivery p99 |
| **replay** (catch-up) | 1000 clients × 200 events | durable `fast`, ursula `memory` (s2 excluded) | 2 | p99 |

Durability mode only affects the **write** path, so the read workloads (sse, replay) run a
single durable config (`fast`). Clients are provisioned well above the bottleneck within
the cluster's pool: the write/replay fleet is many light pods (`FLEET_CPU`, `PER_POD`),
and SSE runs on **one well-provisioned pod** (`SSE_FLEET_CPU` ≈ a full client node) so the
writer + subscribers share one wall clock → clean delivery p99, no cross-pod skew.

The engine (deploy server, run client fleet, merge HDR results, calibrate/pin, sidecar
metrics) is shared in **`scripts/lib-bench.sh`**; target selection (context, image refs,
node selectors) is in **`scripts/target-env.sh`**.

### `DS_TARGET`

```bash
export DS_TARGET=local      # kind cluster, locally-built images, single node (default)
export DS_TARGET=remote     # GKE, Artifact Registry images, role=server/client pools
```

Optional: `KIND_CLUSTER` (default `ds-bench`); for remote, `PROJECT`/`ZONE`/`CLUSTER`
(defaults: gcloud project / `europe-west1-b` / `ds-bench`).

### Where things land

- Per-cell data: `results/bench/bench-<ts>/<cell>-r<rep>/rep1/...` (`merged.json` =
  merged HDR/throughput, `samples.csv` = server RSS/CPU, `verdict.txt`).
- Consolidated: `results/bench/bench-<ts>/summary.tsv` (one row per cell × rep).

---

## 1. Prerequisites

**Local (`DS_TARGET=local`):** Docker running, `kind`, `kubectl`, `envsubst` (gettext),
`python3`. A clone of the server at `../durable-streams`. Nothing in the cloud, no billing.

**Remote (`DS_TARGET=remote`):** `gcloud` authenticated with access to the project, plus
`kubectl`/`envsubst`/`python3`. Images build via Cloud Build (amd64).

> Local builds are **native arch** (`docker build` + `kind load`) — fast, no QEMU, no
> registry. Remote builds go through Cloud Build → Artifact Registry.

---

## 2. Cluster up

```bash
export DS_TARGET=local        # or remote
scripts/cluster-up.sh
```

Creates the cluster (kind single node / GKE server+clients pools), the `ds-bench`
namespace, the `metrics-poller` ConfigMap, and MinIO (the object tier + the HDR-merge
store). Idempotent. **Run this before building images** — for local, `kind load` (next
step) needs the cluster to already exist.

## 3. Build images

```bash
scripts/build-images.sh
```

Builds `ds-bench:dev` (workload client) and `durable-streams:dev` (server, from the
**current `../durable-streams` checkout**, with `FEATURES=tier,strict-uring` so the
`durable:strict-iouring` variant exercises the io_uring fsync executor) and loads them
into the cluster. Iterating on the server? `git -C ../durable-streams checkout <branch>`
then re-run this — that is the inner dev loop.

## 4. Run the matrix

One command for local and remote — `scripts/gke-bench.sh` runs the full
SYSTEMS × WORKLOADS grid (§0), deploying each cell fresh, warming up + settling,
measuring, and appending to `results/bench/bench-<ts>/summary.tsv`.

```bash
# full matrix (local)
DS_TARGET=local CLUSTER=ds-bench scripts/gke-bench.sh

# remote (GKE)
DS_TARGET=remote PROJECT=<gcp> ZONE=<zone> CLUSTER=<cluster> scripts/gke-bench.sh

# quick smoke — one system × one workload × one rep
SYSTEMS='durable:wal' WORKLOADS='write' WRITE_CARDS='1000' REPEATS=1 \
  DS_TARGET=local CLUSTER=ds-bench scripts/gke-bench.sh
```

**Knobs** (override any): `SYSTEMS`, `WORKLOADS` (`write sse replay`), `WRITE_CARDS`,
`SSE_STREAMS`/`SSE_TOTAL_SUBS`, `REPLAY_CONF`, `REPEATS` (default 3),
`WARMUP_SECS`/`SETTLE_SECS`/`DURATION`, `FLEET_CPU` (write fleet), `SSE_FLEET_CPU`,
`PER_POD` (target streams/pod), `WAL_SHARDS`, `TAIL_CACHE_BYTES`.

> **Calibrate / `verdict.txt`.** Write cells run client-unbound at a pinned pod count
> (calibrate-then-pin, below). A cell is `server_bound` (trustworthy ceiling) only if the
> server consumed ≥90% of its CPU budget; otherwise `client_capped` (a lower bound — add
> `PER_POD`/pods). SSE runs on one well-provisioned pod by design (delivery-latency test).

## 5. Read the results

Each run writes `results/bench/bench-<ts>/summary.tsv` — one row per
`(system, variant, workload, params, pods, rep)` with throughput/ev-s, p99, and
cpu_pct. Aggregate across reps (median + CV%) with the shared helpers in
`scripts/render_common.py` (`load_rep` / `aggregate_cell`), which read each cell's
`rep1/{merged.json,samples.csv,verdict.txt}`.

## 6. Report

Render the one consolidated table from `summary.tsv` (§5) and lead with the run context
so it's reproducible:

- `DS_TARGET`, cluster shape, server commit (`git -C ../durable-streams rev-parse --short HEAD`),
  date, the systems/workloads run.
- Headlines: write ops/s + p99 by cardinality; SSE delivery p99 by subscriber count; replay p99.
- Honesty notes: cells marked `client_capped` are lower bounds; the object tier is
  in-cluster MinIO (not cloud S3); `cpu_pct` is durable-only; reps (write/replay 2, SSE 1).

Suggested path: `docs/combined-report-<target>-<date>.md` — produce one per target to diff
local vs cloud.

### Known server limits (now fixed — confirm they stay fixed)

Two limits bounded earlier runs; both are fixed in the server and worth re-confirming:

1. **fd ulimit** — the server stalled at exactly ~1024 concurrent connections (default
   `RLIMIT_NOFILE`). Fixed: the server raises NOFILE at startup (`raise_nofile_limit`) +
   the accept loop backs off on `EMFILE`. **Confirm:** drive >1024 conns (e.g.
   `PARALLELISM=8` × conn 256) and verify the server stays up.
2. **stream-creation timeout** — concurrent `PUT /v1/stream` timed out at ~200. Fixed:
   creation runs off the async worker pool (`spawn_blocking`). **Confirm:** Phase 2 N≥200
   completes.

The `slow` matrices keep conservative caps (N≤200, conns≤256) as safe defaults — raise
them once you've re-confirmed the fixes hold, to chase true (non-capped) ceilings.

## Pod counts & client provisioning

`gke-bench.sh` runs each cell at a **fixed, computed** client pod count
(`MODE=calibrate MAX_BUMPS=0` — no headroom bumping):

- **write / replay** — `ceil(N / PER_POD)` light fleet pods (`FLEET_CPU` each, default
  0.5), capped at `MAX_FLEET_PODS`. Many light pods keep the load generator well above
  the server's needs (client-unbound). Lower `PER_POD` / raise `MAX_FLEET_PODS` to add
  client pods, bounded by the cluster's `clients` node pool.
- **sse** — **one** well-provisioned pod at `SSE_FLEET_CPU` (≈ a full client node), so
  writer + subscribers share one wall clock (clean delivery p99).

The pinned count + the running image digest land in `calibration/pins.json` (keyed by
server-image-digest + machine + cpu/mem). Each cell's `verdict.txt` records whether the
server was the bottleneck (`server_bound`, a trustworthy ceiling) or the client capped
it (`client_capped`, a lower bound — add client pods).

## 7. Tear down

```bash
scripts/cluster-down.sh           # remote: pass the same ZONE you created with
```

Local: `kind delete cluster`. **Remote: deletes the GKE cluster, verifies it is gone (no
billing), unsets the context — always run this after a cloud run.**

---

## Troubleshooting (practical notes)

- **GKE zone out of capacity** (`does not have enough resources available to fulfill
  request: <zone>`): retry in a SIBLING zone of the same region (so the `benchmarking`
  subnetwork still applies): `ZONE=europe-west1-d scripts/cluster-up.sh`. The kubectl
  context follows the zone (`gke_<project>_<zone>_ds-bench`), so pass the **same `ZONE`**
  to every later phase/render/teardown command. If `n2d-standard-8` is broadly short,
  `n2-standard-8` is an NVMe-capable fallback.
- **Local Docker build wedges or crawls**: Docker Desktop under disk pressure stalls builds
  (the daemon stops accepting new work — even `docker run alpine` hangs). Free it with
  `docker builder prune -af && docker image prune -af` (or full `docker system prune -af
  --volumes`), then re-run `build-images.sh`. Native arm64 build is ~10 min the first time.
- **Every cell is `client_capped`**: the client fleet — not the server — is the bottleneck.
  Raise `PARALLELISM` (or drop `MAX_BUMPS=0`) to add client pods until cells go
  `server_bound` (the trustworthy ceiling).
- **A cell renders `-` / empty**: that cell's fleet errored; the tolerant fleet/coordinator
  waits keep the rest of the matrix running. Inspect `kubectl --context $KCTX -n ds-bench
  logs job/bench-fleet`. Usually a server hiccup or a cap set too aggressively.
- **Iterating on the server**: `git -C ../durable-streams checkout <branch>` → re-run
  `build-images.sh` → re-run the phase. The image is built from the current checkout, so
  that is the whole inner loop.

---

## Configuration reference

All knobs are environment variables (export before the command); defaults in parentheses.

### Target & cluster — `cluster-up.sh`, `target-env.sh`
| var | default | meaning |
|---|---|---|
| `DS_TARGET` | `local` | `local` (kind) or `remote` (GKE) |
| `KIND_CLUSTER` | `ds-bench` | local kind cluster name (context `kind-<name>`) |
| `PROJECT`/`ZONE`/`CLUSTER` | gcloud / `europe-west1-b` / `ds-bench` | remote GKE id; context = `gke_<PROJECT>_<ZONE>_<CLUSTER>` |
| `CLIENT_NODES` | `2` | client node-pool size (remote). More machines = more load-gen capacity. Proven: beyond what the *server's* real bottleneck needs, adding these does nothing. |
| `LOCAL_SSD_COUNT` | `1` | local NVMe SSDs striped (RAID0) under the server data dir. **Raises the disk-write ceiling ≈ 0.6 GB/s × count** (1→~0.6, 4→~2.4, 16→~9 GB/s; max 16 on n2d-standard-8). |
| `SERVER_MACHINE` | `n2d-standard-8` | server node machine type |

### Server flags — durable-streams (passed via `deploy_server`)
| flag | default | meaning |
|---|---|---|
| `--group-commit-window-us` | `0` | **NEW.** fsync group-commit accumulation window (µs). `0` = no batching — each fsync leader flushes immediately (≈ 1 fsync/append under load). `200–500` makes the leader wait so concurrent appends fold into **one** fsync → multi-fold small-write throughput, at ≤ window added p50 latency. Requires the patched server. See "leader election" below. |
| `--splice-appends` | off | zero-copy splice for large appends (the splice cell enables it) |
| `--tier {s3\|local}` | `s3` | cold-tier backend (cold-tier cell uses `local`) |

### Matrix dimensions (slow profile) — the runner files
| var | runner | default | meaning |
|---|---|---|---|
| `SERVER_CPUS` | all | `2 4 8` (scaleout `8`) | server CPU budget(s) swept (cgroup `cpu.max` → tokio worker count) |
| `DURATION` | all | `30`/`25` | seconds per cell |
| `REPEATS` | all | `3` | repeats per cell (renderer takes median + CV%) |
| `READ_SIZES`/`READ_CONNS` | rawpower | `1024 16384`/`16 64 256` | read payload sizes / connections |
| `APPEND_CONNS`/`APPEND_PAYLOADS` | rawpower | `64 256`/`1024 16384` | append connections / payload bytes |
| `FO_SUBS_LIST` | rawpower | `1 10 100` | fan-out subscriber counts |
| `SKIP_SPLICE`/`SKIP_COLD` | rawpower | `0`/`0` | set `1` to skip the splice / cold-tier cells |
| `MS_COUNTS` | scaleout | `10 50 100 200` | multi-stream stream counts |
| `MF_PAIRS` | scaleout | `10:10 20:10 10:20` | multi-fan-out `M:S` (streams:subs-per-stream) |

### Headroom guard — `lib-bench.sh`
| var | default | meaning |
|---|---|---|
| `PARALLELISM` | `4` | *initial* client pods per cell |
| `MAX_PODS` | `16`/`32` | ceiling the guard bumps to (doubling: P→2P→4P…). Note doubling: e.g. with `MAX_PODS=64`, P=8 reaches 8→16→32→64; set ≥ the count you want or it stops one rung early. |
| `MAX_BUMPS` | `1`(fast)/`8`(slow) | max doublings; `0` = fixed `PARALLELISM` (no bump) |
| `FLEET_TIMEOUT`/`COORD_TIMEOUT` | `180`/`90` | seconds before a hung fleet/coordinator is abandoned (tolerant — keeps the matrix going) |

---

## io_uring (Linux) — seccomp requirements

The `durable:strict-iouring` variant runs the server built `--features strict-uring` with
`--strict-io-uring` (a shared io_uring ring batching strict-mode `fdatasync`s; it falls back
to `spawn_blocking` if io_uring is unavailable). The harness is unchanged — only the io_uring
syscalls must be permitted at runtime:

- **Remote (GKE):** the server pod sets `securityContext.seccompProfile.type: Unconfined`
  (`gke/durable-streams.yaml`) — Docker 25 / containerd's default seccomp blocks
  `io_uring_setup/enter/register` (moby#46762), and a Pod-Security/CIS policy can impose
  `RuntimeDefault`; `Unconfined` permits them. Confirmed on our cluster: **GKE Standard**
  (not Autopilot), **COS** node image, **kernel 6.12** (≥ 6.0 → io_uring *and*
  `IORING_OP_SEND_ZC` zero-copy-send both work), **no gVisor/sandbox** (gVisor has no
  io_uring — do not route this pod through it). No other change needed.
- **Local (kind) — works directly, no extra setup** (verified empirically). kind launches its
  node containers `--privileged` with `seccomp=unconfined apparmor=unconfined`, so the node
  boundary does NOT block io_uring — the *only* gate is the **pod's** `seccompProfile`, and we
  already set it to `Unconfined`. Test result: an `Unconfined` pod → `io_uring_setup` returns an
  fd (PERMITTED); a `RuntimeDefault` pod → EPERM (BLOCKED). Docker Desktop's VM kernel is **6.10**
  (≥ 6.0), so **io_uring AND `IORING_OP_SEND_ZC` zero-copy-send both work inside kind** — no
  separate Linux VM and no special kind config required. So the full multi-pod harness runs real
  io_uring locally. (Outside k8s, `docker run --security-opt seccomp=unconfined …` works too for
  a single-instance smoke.)
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
