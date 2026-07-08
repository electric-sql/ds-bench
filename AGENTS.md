# AGENTS.md — operating the ds-bench harness

Practical guide for an agent (or engineer) driving this repo. For the conceptual
overview of *what* each workload measures, see [`README.md`](README.md); this file
covers *how to run it*, the typical deployment we use, and the gotchas that bite.

> **Golden rule: always tear clusters down.** Remote runs are billable GKE clusters.
> Suites self-teardown on clean completion but **leave clusters up on any error**
> (for resume). Arm the watchdog and verify `gcloud container clusters list` is
> empty when you're done. See [Teardown](#5-teardown-discipline).

---

## 1. What it does

`ds-bench` is a single-node, server-agnostic benchmark harness for durable-stream
servers. A **suite** (`suites/*.json`) declares the workload, the systems/configs,
and the sweep; `scripts/bench` brings up a cluster, deploys each server fresh,
drives a Kubernetes client fleet, merges per-pod HDR histograms into fleet-wide
percentiles, and writes per-cell results.

| Workload | Measures | Driver |
|---|---|---|
| **Write** (saturation) | append/s at saturation + tail latency + pod memory | `suites/run-{durable,ursula,s2,node}.json` |
| **Sustained** | latency + server-memory stability over a long window | `suites/sustained.json` |
| **Catch-up** | per-client replay latency + body size | `suites/catchup-{durable,ursula,s2}.json` |
| **Reads** (`catchup` / `long-poll` / `sse`) | live-tail delivery latency vs connections | `suites/reads-{catchup,longpoll,sse-remote}.json` |
| **SSE fan-out** | per-event delivery latency + memory vs subscriber count | `scripts/run-sse.sh` |

Systems under test: **durable-streams** (Rust; `wal` / `wal-tailcache` / `memory`
configs), **ursula** (`URSULA_WAL=memory|disk`), the **Node.js reference** (`node`),
and **S2 / s2lite**.

---

## 2. Running a benchmark

```bash
scripts/bench <suite.json> {run|report|teardown|teardown-if-complete}
```

- **run** — bring up one cluster per mode, walk every `(mode, config, stream_count)`
  cell, write `results/<suite>/<label>/cells.json`, then report + maybe-teardown.
- **report** — regenerate `results/<suite>/{aggregate.csv,aggregate.json,report.md}`
  from local data. No cluster needed.
- **teardown** — delete only the clusters *this suite* created (tracked in
  `.bench-state/<suite>.json`).

**Target selection** — set `DS_TARGET` explicitly:

| `DS_TARGET` | Where | Images | Pulls | Server |
|---|---|---|---|---|
| `local` | kind, single node (`kind-ds-bench`) | locally built + `kind load` | `IfNotPresent` | 2 CPU / 2Gi |
| `remote` | GKE, role node pools | Artifact Registry | `Always` | 4 CPU / 16Gi |

The full `suites/*.json` are sized for GKE; for kind use the `*-local` suites (or
shrink `stream_counts` / ladders in a copy).

**Resume semantics** — `run` is resumable: a cell is skipped when its stored status
matches the skip state (`saturated` for write, `done` for sustained/catchup/reads).
The resume key is `server_image_digest = sha256(deployed_image_ref + config_args)[:12]`
— it hashes the image **ref string**, not the registry content. So **rebuilding an
image under the same tag (`:dev`) does NOT invalidate finished cells.** To force a
true re-run, delete the results dir first:

```bash
rm -rf results/reads-sse-remote && scripts/bench suites/reads-sse-remote.json run
```

---

## 3. Typical remote deployment

One **GKE cluster per deploy-mode**, named `bench-<mode>`, in `region-<zone>` where
the zone is derived from the mode in `scripts/bench`:

| mode | cluster | zone (region `europe-west4`) |
|---|---|---|
| `wal` (durable) | `bench-wal` | `…-a` |
| `ursula` | `bench-ursula` | `…-b` |
| `s2` | `bench-s2` | `…-c` |
| `node` | `bench-node` | `…-b` (reuses ursula's — the matrix caps at 3 parallel) |

A suite may override `cluster.cluster_name` / `cluster.zone` to pin its own.

The production suites (`run-durable`, `run-ursula`, `reads-*`) pin:
- **Server:** `c4d-standard-16-lssd`, **CPU-pinned to 4** (`SERVER_CPUS=4`,
  `SERVER_MEM=16Gi`) — so node size doesn't change the server's numbers. (Note:
  `target-env.sh`'s bare default is the cheaper `c4d-standard-8-lssd`; the suite's
  `cluster.server_machine` wins.)
- **Client fleet:** `n2d-standard-32` **Spot**. `client_nodes` 2–4 covers the legacy
  catch-up/reads suites; the **pool write-saturation** sweep (§7) needs more (≈4–6 at
  `batch:1` to reach a multi-core server's ceiling) unless `batch` is raised — sized
  per §7 step 3, and consider `n2d-highcpu-32` to cut fleet cost.
- **`FLEET_CPU=0.5`** — a scheduling *reservation* only (no CPU limit; pods burst to
  node cores). Many light pods so the *server* is the bottleneck.
- **`pods=1`** is required for the live read modes (`long-poll`, `sse`) so the writer
  and readers share one process and one wall clock.

Everything points at a shared single-node MinIO; only the system under test runs
while it is measured.

---

## 4. Multi-system orchestration & image builds

**Run the whole write matrix in parallel:**

```bash
[SKIP_BUILD=1] [MAX_PARALLEL_CLUSTERS=3] scripts/run-matrix.sh [suite-basename ...]
# default suites: run-durable run-ursula run-s2 run-node  (durable first = long pole)
```

Each suite is its own cluster/zone, so parallel runs never collide; each
self-tears-down on clean completion. **`SKIP_BUILD=1` reuses the Artifact Registry
images instead of rebuilding** — see the gotcha below.

**SSE fan-out** runs on one cluster (`bench-sse`, `europe-west4-a`):

```bash
SKIP_BUILD=1 scripts/run-sse.sh   # SYSTEMS: durable:walnew[-cache], ursula:memory|disk, s2
# 1 stream × subscribers {1,10,100,1000}; writes results/sse-comparison.{md,csv} + results/final/sse/
# guaranteed teardown + .bench-state/sse.done marker
```

**Building images** (`scripts/build-images.sh`):
- `local` → native `docker build` + `kind load` (no registry).
- `remote` → Cloud Build → Artifact Registry
  (`europe-west1-docker.pkg.dev/$PROJECT/ds-bench/...`), via `scripts/gke-push-images.sh`.
- Builds `ds-bench:dev`, `durable-streams:dev`, `durable-node:dev` (`BUILD_NODE=0` to skip).

> **The durable image source.** `build-images.sh` / `gke-push-images.sh` build
> `durable-streams:dev` from the server crate inside `DS_RUST_REPO` (default
> **`../electric-ds-rust`**), auto-detecting the crate dir:
> `packages/durable-streams-rust` (the electric monorepo) is preferred,
> `packages/server-rust` is the legacy fallback, and `DS_RUST_CRATE` (absolute or
> repo-relative) overrides both. So building a feature branch is just: check out
> the branch in `DS_RUST_REPO`, run `DS_TARGET=remote scripts/build-images.sh`
> (`BUILD_NODE=0` to skip the node image), then run suites with `SKIP_BUILD=1` so
> `run-matrix.sh` doesn't rebuild from a different source. Verify which image a
> cluster ran by diffing the Cloud Build source tarball against your commit — the
> resume digest won't tell you (it's tag-based).

---

## 5. Teardown discipline

- Suites **self-teardown only when complete + results collected**; an `errors` or
  `incomplete` status **keeps the cluster up** so you can fix and resume.
- `BENCH_KEEP_CLUSTER=1` always keeps clusters.
- **Arm the watchdog** (detached) for any unattended run — it force-deletes
  matching clusters at a deadline unless the done-marker appears first.
  **ALWAYS scope `CLUSTER_FILTER` to the clusters your run owns**: the default
  (`^bench-`) matches everything, and an unscoped watchdog from a side
  experiment once swept a running campaign's clusters mid-deploy when its own
  done-marker appeared (it "sweeps leftovers" on stand-down).
  ```bash
  DEADLINE_SECS=25200 DONE_MARKER="$PWD/.bench-state/run-all.done" CLUSTER_FILTER='^bench-cpu' \
    nohup bash scripts/teardown-watchdog.sh >/tmp/watchdog.log 2>&1 &   # default 28800s = 8h
  # signal clean completion so it stands down:  touch .bench-state/run-all.done
  ```
- **Manual sweep** (always do a final check):
  ```bash
  gcloud container clusters list --project "$PROJECT" --format='value(name,location,status)' | grep -i bench
  gcloud container clusters delete <name> --zone <zone> --project "$PROJECT" --quiet
  ```
  A delete fails while a cluster is `PROVISIONING`/`RECONCILING` — retry until gone.

---

## 6. Results layout & provenance

```
results/<suite>/
  aggregate.csv  aggregate.json  report.md      # tracked (curated)
  <mode-or-label>/cells.json                     # tracked (result + resume store)
  <mode-or-label>/cells/ … samples.csv *.hdr     # gitignored (bulky raw)
```

`.gitignore` keeps `cells.json` / `report.md` / `*.csv` but drops `cells/`,
`samples.csv`, `merged.json`, `*.hdr`, `verdict.txt` — **under `results/**` only**.

**Archived full runs** go in a dated folder with a provenance file:

```
results-YYYY-MM-DD/
  PROVENANCE.md          # commit SHAs (durable-streams + ds-bench), image digests, workloads, hardware
  run-durable/ run-ursula/ run-s2/ run-node/ sse/ reads-*/   # curated per-suite
```

**`results-2026-06-30/` is the canonical example** of this pattern — copy its
`PROVENANCE.md` structure (versions with full SHAs, image `sha256`, workloads,
hardware, and a cell-level status section noting any error cells + cause).

> **⚠️** The `.gitignore` raw-artifact patterns are scoped to `results/**`, **not**
> `results-YYYY-MM-DD/`. Before committing a dated archive, prune the raw artifacts
> yourself so only curated files land:
> ```bash
> find results-YYYY-MM-DD -type d -name cells -exec rm -rf {} +
> ```

---

## 7. Write saturation: calibrate the pod, then scale pods

**Fleet start barrier + window alignment.** Saturation cells SUM per-pod rates,
which only measures the server when every pod's measure window covers the same
wall time. The walker therefore runs the fleet under a **start barrier**
(`BARRIER_DIR`, on by default in `lib-saturate.sh`): each pod holds after its
stream-creation phase (`src/barrier.rs`, ready/go files relayed to MinIO by the
pod wrapper in `gke/bench-job.yaml`), and the host releases the whole fleet at
one shared go time once all `PARALLELISM` ready markers are up
(`_barrier_release_fleet`; `BARRIER_SETUP_TIMEOUT_SECS`, default 900). Pods then
stamp `measure_{start,end}_unix_ms` into their JSONs and hdr-merge verifies the
fleet actually measured together (`windows_aligned`: span ≤ 2× window); a
misaligned rung records as `error/misaligned_windows` instead of an inflated
number. Without this, K8s scheduling waves + per-pod setup staggered the 8 s
windows across minutes at ≥160 pods, and the sum multiply-counted capacity (a
4-vCPU server "measured" at 2.9M appends/s while its disk telemetry showed it
mostly idle). Barrier = prevention; the aligned check = verification — both stay.

**Terminology.** Keep three things separate: the **workload** (the operation under
test — here, *append*); the **offered load** (the demand profile —
`concurrency = pods × connections`, `payload_bytes`, `batch`, rate); and the **fleet**
(the client pods/nodes that *generate* that load — the dominant cost). State init
(creating `stream_counts` streams up front) is a separate one-time setup phase, not
part of the offered load. "Optimize fleet cost" = generate the same offered append
load with fewer/cheaper client vCPU; it changes neither the workload nor the state.

The write/saturation client produces the offered load with a **bounded-concurrency
pool** (`multi-stream --connections C`, set per-suite via `saturation.connections`):
`--streams N` is the **global** key domain; pod i of P (from
`DS_BENCH_INSTANCE`/`DS_BENCH_SHARDS`) owns the disjoint slice `[i·N/P, (i+1)·N/P)`
and runs exactly **C worker-connections**, each cycling PLAIN appends (no producer
sessions/idempotency) round-robin over a disjoint sub-slice of the pod's slice. So
the key space is covered evenly and **no two pods or workers ever share a stream**
(no cross-client appender-lock interference). Each pod **pre-creates its slice in a
setup phase BEFORE the barrier** — the measure window contains appends only. A
404→create→retry fallback exists but any use is counted in the pod JSON's
`lazy_creates`; **nonzero `lazy_creates` means creation leaked into the load phases
and the cell is suspect** (this was the random-domain client's failure mode: no
setup phase, so high-cardinality cells measured the creation storm, not appends).
Offered load is `pods × C`, **decoupled from stream count**.

> The legacy default `connections: 0` = one in-flight append **per stream**. At high
> streams/pod this makes the *client pod*, not the server, the bottleneck: the pod's
> throughput becomes `streams ÷ round-trip-latency` and collapses (multi-second tail
> latency + mass timeouts) while the server sits idle. **Never use `connections: 0`
> for high-cardinality (≥ tens of k streams) write sweeps** — it produces false, low,
> streams/pod-dependent ceilings.

**Recipe for a new write suite — calibrate the pod, then launch as many as needed:**

1. **Find the single-pod max.** Run **one** fleet pod against an *over-provisioned*
   server (give the server far more cores than one pod can saturate) and sweep
   `--connections` (e.g. 128 → 256 → 512 → 1024 → 2048) at the suite's `fleet_cpu`
   and `payload_bytes`. The pod's ops/s rises, then **plateaus when the pod itself
   saturates** — that plateau is the single-pod max. (It is per `fleet_cpu`, per
   `payload_bytes`, and per `batch`; re-calibrate if any changes.) A pod is healthy
   only while latency
   stays low and errors are 0; the plateau is the last point before they degrade.
2. **Cap the per-pod reference at 80 % of that max.** Choose the `connections` value
   whose ops/s ≈ `0.8 × single-pod-max` (just below the knee) and put it in
   `saturation.connections`. This keeps every pod in its linear region — never the
   bottleneck — so the sweep measures the *server*, not the client.
3. **Scale pods to saturate the server — starting from 1 pod.** With per-pod load
   fixed at the 80 % reference, the `pod_ladder` ramps total offered load
   (`pods × connections`) until server throughput plateaus
   (`saturation.plateau_pct`). **Start the ladder at 1 pod** — the low rungs are
   cheap and they are the only place service latency is measurable (see below).
   **Launch as many pods as the server needs.** `stream_counts` only sets
   cardinality (keep `perpod = streams ÷ pods ≥ connections`), not load. Size
   `client_nodes` so the top rung's `pods × fleet_cpu` fits with headroom. A suite
   may pin the server's vCPU budget via `cluster.server_cpus` (else env
   `SERVER_CPUS`, default 4 remote / 2 local).

In short: **each pod is calibrated to 80 % of its own ceiling; a test launches
however many such pods are required to find the server's ceiling.** Treat any cell
where per-pod latency/errors degrade as invalid (client-bound) — lower `connections`
or raise `fleet_cpu` and re-calibrate.

**Plateau robustness (`saturation.patience`, `saturation.repeats`).** The walk stops
when it sees `patience` **consecutive** rung-to-rung gains at or below `plateau_pct`
(`saturation.patience`, default 1 = the legacy single-shot rule). Set **`patience: 2`**
on any real write suite: run-to-run throughput noise is easily in the 5–15 % band, and
a single unlucky-low rung otherwise triggers a *false* plateau and an under-reported
ceiling (`saturation.plateau_pin`). The pinned rung's headline throughput is then the
**mean over `repeats` confirm re-runs** (`repeats: 2`+ gives a replicated number, not a
single 20-25 s shot); with `repeats: 1` it falls back to the walk's pin reading. The
`write-wal-vs-mem-*` reference suites ship `patience: 2, repeats: 2`. (`plateau_pct: -100`
still forces the full ladder — no plateau, top rung recorded as a `†` lower bound.)

**Latency is only meaningful BELOW the knee.** A closed-loop fleet driven past the
server's ceiling measures its own queueing — `p50 ≈ in-flight ÷ ceiling` (Little's
law) — not the server's service time. Manually verified 2026-07-08 on wal@100k
(4 vCPU): plain curl unloaded = **1.0 ms**; 256 in-flight = 5 ms @ 45k ops/s;
4096 in-flight = **66 ms** @ 61k — same server, the "latency" is the queue. The
machinery accounts for this: every walk rung records its own merged p50/p99
(`walk: [pods, thr, p50, p99]`), and `report.py` quotes latency from the **knee**
rung (largest at ≤80 % of peak, `knee_*` columns in aggregate.csv) while labelling
the plateau rung's latency as saturation queueing. Never quote a saturation-rung
p50 as "the latency" — sanity-check any suspicious latency with
`scripts/manual-wal-latency.sh` (curl + single-pod ramp, independent of the fleet
path). Corollary: the plateau rule stops near the knee, so "saturation throughput"
is the knee capacity; pushing thousands more in-flight buys ~25 % more throughput
at 10× the latency (that asymptote is not the number we report).

**Accuracy ground truth** (run after any client/harness change): each pod JSON
carries `ok_total_all_phases` + `pod_slice_lo/hi`; `ds-bench verify-offsets` sums
server-side `stream-next-offset`; `scripts/verify-write-accuracy.sh` compares the
two (+ slice tiling, `lazy_creates=0`, coverage) and
`scripts/verify-accuracy-cell.sh` runs one local cell end-to-end — expected
result: **server records == client records, delta 0**.

### Fleet cost levers (the fleet, not the server, dominates run cost)

The client fleet is ~4× the server's cost, so optimize there. In descending impact:

1. **Batch records per request** (`saturation.batch` / `multi-stream --batch N`,
   pool only). The durable server flattens a JSON-array body into N records under
   **one appender-lock + one fsync**, so one POST carries N appends. Since the pool
   client is request-rate-limited, records/s per client vCPU scales ~linearly with N
   — measured **~10× at N=10, ~35× at N=50, ~140× at N=200** (256 B payload). This is
   the dominant lever: it cuts fleet vCPU per record/s by 1–2 orders of magnitude
   (and lifts the server ceiling, since the per-append lock/fsync is amortized).
   `batch>1` switches the body to `application/json`, so streams are auto-created as
   `application/json` (a mismatched content-type is a 409). Re-calibrate after
   changing `batch` — the single-pod max changes. Note: batching models a *batching
   producer*; for a strict one-write-per-request workload keep `batch: 1`.
2. **Don't overshoot the ladder.** Stop the `pod_ladder` at the throughput plateau;
   rungs past it (over-saturation) waste fleet nodes. Size `client_nodes` to the
   plateau rung, not the max rung.
3. **Cheaper client machine family.** The fleet is CPU-bound with tiny memory (the
   pool client holds only ~C histograms + N×8 B of seq), so use a cost-optimized,
   low-RAM family on Spot: `n2d-highcpu-32` (≈20 % cheaper/vCPU than `-standard`),
   `t2d-standard`, or `t2a` (Arm — ds-bench builds arm64).
4. **Calibrate the cheapest pod size.** Sweep `fleet_cpu` (1/2/4) in calibration and
   pick the best **ops/s per vCPU**, not just the highest single-pod throughput.

### Measured reference points (durable, 256 B payload, `batch:1`, pool `fleet_cpu=2`)

**2026-07-08 corrected campaign** (barrier-aligned, knee methodology; server
`c4d-standard-16-lssd`, shards = worker-threads = pin; plateau thr, knee p50 —
`results/write-wal-vs-mem-cpu4/FINDINGS.md`):

| pin | streams | wal | wal knee p50 | memory | memory knee p50 |
|---|---|---|---|---|---|
| 4 vCPU | 100k | 47k | 4.5 ms | 315k | 1.2 ms |
| 4 vCPU | 500k | 31k | 6.7 ms | 226k | 1.1 ms |
| 8 vCPU | 100k | 43k | 5.0 ms | 526k | 1.2 ms |
| 8 vCPU | 500k | 29k | 6.9 ms | 323k | 1.3 ms |

- **wal does not scale with the CPU pin** at shards = cores (fsync-lane bound at
  ~25–30 % CPU); the shard count is the parallel-fsync knob (`run-durable-tune`:
  s16t4 ≈ 380k @ 200k streams). **memory scales with cores** at ~1–2 ms p50.
- **Cardinality cliff:** 100k → 500k streams costs wal ~33 % and memory ~28–39 %
  in both pins — present in every build (registry/page-cache/fd physics, see
  `WRITE_BOTTLENECKS_1M.md` in the server crate), NOT coordination.
- Unloaded single-request wal append (curl): **~1.0 ms**.
- **Single-pod max** ≈ 45–60k ops/s into wal by ~256 connections; `connections: 256`
  remains the standard per-pod reference.
- **Cost** (list, europe-west4, Spot): fleet 5–7×`n2d-standard-32` ≈ $2–3/hr ·
  server ≈ $0.5/hr · GKE ≈ $0.1/hr; the corrected 2-suite campaign ≈ $6–8.

**Older (pre-barrier) reference points are inflated** — treat the 2026-06-30
"1.48M @ 200k / 1.15M @ 500k on 32 vCPU" numbers (`run-durable-pool2/FINDINGS.md`)
as upper bounds only: they predate the start barrier, and misaligned fleet windows
multiply-count capacity (the documented 2.9M artifact). Raising `batch` still cuts
fleet cost 10–140× and lifts the server ceiling — re-calibrate after changing it.

### Iterating on server performance LOCALLY (the cardinality cliff / wal CPU-scaling)

Both open server-side problems (throughput falling with stream count; wal flat
across CPU pins) **reproduce on kind** — iterate on a laptop in ~15-minute
cycles with `suites/write-cliff-local.json` (+ `-cpu4` for the CPU probe) and
compare shapes with `scripts/compare-cliff.py`. The full loop, baselines, and
validity checks are documented WITH THE SERVER CODE:
`packages/durable-streams-rust/CARDINALITY_CLIFF_REPRO.md` in the electric repo
(local findings snapshot: `results/write-cliff-local/FINDINGS.md`). Keep the
suite at [1k, 10k, 50k] streams — the cliff is unambiguous by 50k and larger
counts only slow the loop.

---

## 8. Known limits & gotchas

- **Catch-up OOM ceiling.** `reads-catchup` materializes the *full resident stream
  body per reader* (`resp.bytes()` in `ds-bench/src/reads.rs::catch_up_once`), so
  peak client memory ≈ `connections × ~2 × seed_bytes`. The fleet pod
  (`gke/bench-job.yaml`) has a hard **4 GiB** limit, so at the default 16 MiB seed it
  **OOMKills above ~64 connections**. Safe ceilings: **durable ≤ 64 connections**;
  **ursula ≤ 10 streams *and* ≤ 32 connections** (ursula catch-up is heavier — it
  OOMs at 100 streams for every connection count). To probe higher fan-out, raise the
  pod `limits` or shrink `seed_bytes`. Long-poll and SSE are streamed (not resident)
  and have no such limit — they scaled cleanly to 2048 connections.
- **`container not found ("metrics")` in logs = a fleet-pod OOM.** The metrics
  sidecar dies with the pod; the symptom surfaces as `status=error` cells. Check
  `kubectl get pod` for `OOMKilled` before assuming a metrics/port-forward bug.
- **Resume digest is tag-based** (§2) — don't trust "all cells done" to mean the
  current image content was used; it only means the same image *ref* was.

---

## 9. Prerequisites & tests

- `kubectl`, `python3` (3.x, stdlib only), Docker. Local: `kind`. Remote: `gcloud`
  authenticated + an Artifact Registry repo. Override `PROJECT`, `AR_LOCATION`
  (`europe-west1`), `AR_REPO` (`ds-bench`), `ZONE`, machine types via env /
  `scripts/target-env.sh`.

```bash
# Unit tests (no cluster):
cd scripts && for t in *_test.py; do python3 "$t"; done
for t in scripts/*_test.sh; do bash "$t"; done
```
