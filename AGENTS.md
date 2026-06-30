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
- **Client fleet:** `n2d-standard-32` **Spot**, `client_nodes` 2–4.
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

> **⚠️ Gotcha — the durable image source.** `build-images.sh` builds
> `durable-streams:dev` from `DS_RUST_REPO/packages/server-rust`, default
> **`../electric-ds-rust`**. If you need a *specific* server build (e.g. a feature
> branch in the `electric` monorepo's `durable-streams-rust` crate), do **not** let
> the matrix rebuild it — build it yourself and reuse it:
> ```bash
> # build the exact crate dir you want, tagged :dev, via Cloud Build
> CRATE=/path/to/electric/.../packages/durable-streams-rust
> cp dockerfiles/durable-streams.Dockerfile "$CRATE/Dockerfile"
> gcloud builds submit "$CRATE" --project "$PROJECT" \
>   --tag europe-west1-docker.pkg.dev/$PROJECT/ds-bench/durable-streams:dev
> rm -f "$CRATE/Dockerfile"
> # then ALWAYS pass SKIP_BUILD=1 so run-matrix doesn't clobber it with the default source
> SKIP_BUILD=1 scripts/run-matrix.sh run-durable ...
> ```
> Verify which image a cluster ran by diffing the Cloud Build source tarball against
> your commit — the resume digest won't tell you (it's tag-based).

---

## 5. Teardown discipline

- Suites **self-teardown only when complete + results collected**; an `errors` or
  `incomplete` status **keeps the cluster up** so you can fix and resume.
- `BENCH_KEEP_CLUSTER=1` always keeps clusters.
- **Arm the watchdog** (detached) for any unattended run — it force-deletes all
  `bench-*` clusters at a deadline unless the done-marker appears first:
  ```bash
  DEADLINE_SECS=25200 DONE_MARKER="$PWD/.bench-state/run-all.done" \
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

## 7. Known limits & gotchas

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

## 8. Prerequisites & tests

- `kubectl`, `python3` (3.x, stdlib only), Docker. Local: `kind`. Remote: `gcloud`
  authenticated + an Artifact Registry repo. Override `PROJECT`, `AR_LOCATION`
  (`europe-west1`), `AR_REPO` (`ds-bench`), `ZONE`, machine types via env /
  `scripts/target-env.sh`.

```bash
# Unit tests (no cluster):
cd scripts && for t in *_test.py; do python3 "$t"; done
for t in scripts/*_test.sh; do bash "$t"; done
```
