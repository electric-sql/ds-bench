# Write-Throughput Benchmark Redesign — Design

**Date:** 2026-06-23
**Status:** Draft for review
**Scope:** Redesign the **write-throughput** benchmark into a declarative, resumable, saturation-finding suite. SSE and replay are out of scope except for small clarifications (below).

---

## 1. Motivation

Today's write-throughput methodology is unreliable: it runs a **fixed pod count per stream-count** (`pods = ceil(streams / PER_POD)`), so it does not actually find each implementation's ceiling. This session repeatedly mistook the **load generator** for the server limit:

- durable:wal 100k read "200k" at 128 pods → 402k at 300 pods (client-bound, not a server limit).
- s2 100k read "0" (under-provisioned) → ~100k once driven (not an object-store limit).
- wal 10k read "495k" at 40 pods → 635k at 200 pods.

We also burned enormous time **creating and tearing down whole clusters per experiment** (~10 min each), when the cluster can persist and only per-cell state needs clearing.

**Goal:** a benchmark where you edit one JSON file, run one script, and get a report — and where each `(mode, stream-count)` cell is driven with **increasing client load until the server saturates**, so the number is a real ceiling, not a load-generator artifact.

---

## 2. Approach

**Thin orchestrator reusing the proven engine.** The existing `scripts/lib-bench.sh` already contains stable, reusable building blocks — `deploy_server`, `run_fleet_and_coordinator`, `reset_sidecar_samples`, `collect_sidecar`, HDR-merge, and `scripts/saturation.py` (the plateau/CPU classifier). We keep these and add a new declarative driver + a per-stream-count saturation walker + a report generator. We do **not** rewrite the deploy/fleet/merge/saturation engine.

(Rejected: extending `gke-bench.sh` — it is built around fixed-pods-per-cell and fights the ramp model. Rejected: full rebuild — wasteful; the engine is solid.)

---

## 3. The declarative suite (one JSON, one driver)

A benchmark run is fully described by a **suite JSON file**. One driver runs it end-to-end and can tear down exactly the clusters it created.

### 3.1 Suite JSON schema

```json
{
  "suite": "write-throughput",
  "cluster": {
    "server_machine": "c4d-standard-16-lssd",
    "client_machine": "n2d-standard-32",
    "client_nodes": 6,
    "region": "europe-west4"
  },
  "saturation": {
    "plateau_pct": 10,
    "fleet_cpu": 0.5,
    "repeats": 3,
    "warmup_secs": 15,
    "measure_secs": 20
  },
  "modes": ["wal", "ursula", "s2"],
  "stream_counts": [1, 10, 100, 1000, 10000, 100000],
  "pod_ladder": {
    "1":      [2, 4, 8],
    "10":     [2, 4, 8],
    "100":    [4, 8, 16],
    "1000":   [12, 16, 20, 24, 32],
    "10000":  [32, 64, 96, 128, 160, 200],
    "100000": [128, 200, 256, 320, 400, 512]
  }
}
```

**Field semantics:**

- `cluster` — machine types, client-node count, and region. The driver creates one cluster per mode (see §6), assigning each a distinct zone within `region` to avoid the kubeconfig race.
- `saturation.plateau_pct` — throughput-growth threshold below which a doubling-ish step counts as saturated (the **primary, CPU-independent** signal).
- `saturation.fleet_cpu` — per-pod CPU reservation (0.5; never raise to 2 — it over-subscribes the client pool and causes scheduling races).
- `saturation.repeats` — measurement reps **at the pinned (saturating) pod count only**, not at every ladder rung (the ramp uses 1 rep per rung to move fast; reps are spent confirming the pinned point).
- `pod_ladder` — **per-stream-count** ordered list of pod counts to walk. The first rung is the empirical seed (start point); the last is the climb ceiling; the spacing is coarse→fine. This **replaces** a global ladder + separate seeds.

### 3.2 Driver: `scripts/bench`

```
scripts/bench <suite.json> run        # cluster-up (per mode) → sweep → gather → report
scripts/bench <suite.json> report     # regenerate report from existing results (no cluster)
scripts/bench <suite.json> teardown   # delete exactly the clusters this suite created
```

- `run` is **idempotent and resumable** — re-running continues from where it left off (see §5, §7).
- The driver records the clusters it created in a **state file** `.bench-state/<suite>.json` (cluster names, zones, creation timestamp). `teardown` reads this file and deletes only those clusters; it never deletes a cluster the suite did not create.

---

## 4. The saturation walker

For each `(mode, stream_count)` cell, the walker drives increasing client load until the server saturates.

### 4.1 Algorithm

```
ladder = pod_ladder[stream_count]          # e.g. [32, 64, 96, 128, 160, 200]
prev_thr = 0
for pods in ladder:
    reset_state(mode)                       # §5 — fresh server, empty data dir
    thr, p99, cpu = run_cell(mode, stream_count, pods, reps=1)
    if cell_failed(thr):                    # fleet errored / creation-choke / thrash
        record(cell, status="error", pods=pods); break_or_flag()
    gain = (thr - prev_thr) / prev_thr      # (guard prev_thr>0)
    if gain < plateau_pct/100:              # PLATEAU → saturated one rung back
        pin(stream_count, pods=prev_pods, thr=prev_thr, saturated=true, reason="plateau")
        confirm_reps(mode, stream_count, prev_pods, reps)   # repeats at the pinned point
        break
    prev_pods, prev_thr = pods, thr
else:                                        # ladder exhausted, never plateaued
    pin(stream_count, pods=last, thr=prev_thr, saturated=false, reason="ladder_exhausted")
```

- **Primary signal: throughput plateau** (`gain < plateau_pct`). This is reliable even where `cpu_pct` is not (it is unreliable above ~10k streams).
- **Secondary signal: CPU** (`saturation.py` already returns "cpu" when cpu_pct ≥ 90%×cores). When the CPU signal is trustworthy (low cardinality) and fires first, it also pins. Throughput-plateau governs at high cardinality. **Note:** `cpu_pct` is instrumented for **durable (wal) only** — ursula and s2 report 0, so their saturation relies **solely on the throughput-plateau signal**. This makes the plateau signal the load-bearing one for two of three modes, reinforcing it as primary.
- **Failure handling (NEW):** a cell whose fleet errors, chokes on stream creation, or thrashes (throughput collapses to ~0 with CPU busy) is recorded `status="error"`, **not** pinned as a real number. This prevents the 100k creation-choke from masquerading as a saturation point.
- The ladder uses **1 rep per rung** (move fast); `repeats` are spent only re-confirming the pinned point.

### 4.2 Resumability and ladder extension

State lives in a **single per-mode results file** — `results/<suite>/<mode>/cells.json` — which doubles as the report source (§7). There is **no separate `pins.json`** (the old calibrate→measure handoff it served no longer exists). Each cell entry records: stream_count, the walk (`pods → thr` at each rung), the pinned pods + throughput + p99, `saturated?`, `reason`/`status`, and the **server image digest** (for build-invalidation — a changed digest re-runs that cell). On `run`:

- A cell already `saturated: true` (same image digest) is **skipped**.
- A cell `saturated: false, reason: "ladder_exhausted"` is **resumed**: the driver appends higher rungs to that stream-count's ladder (configurable growth, e.g. ×1.5 from the last rung up to a hard cap) and walks only the new rungs.
- A cell `status: "error"` is surfaced in the report as a known failure and **not silently retried** (retrying a creation-choke just re-chokes); fixing it is a separate action.
- A cell whose recorded image digest differs from the current server build is **invalidated and re-run**.

So a re-run only does **unsolved work** — exactly the "if saturation wasn't found, don't re-run all numbers" requirement.

---

## 5. State clearing (per-mode reset)

Between every cell, the server is reset to empty state **without recreating the cluster**. The mechanism is per-mode because the backing store differs:

- **wal (durable-streams):** `kubectl rollout restart` the server Deployment → a new pod gets a fresh `emptyDir`. An **initContainer** runs `rm -rf /data/*` before the server starts, guaranteeing an empty data dir **even on the NVMe-backed `emptyDir`** (belt-and-suspenders against any local-SSD reuse). Wait for readiness before the next cell.
- **ursula:** same pattern — `rollout restart` + initContainer wipe of its data/WAL dir.
- **s2:** s2's stream state lives in the **MinIO object store**, so a pod restart alone does not clear it. The s2 reset additionally **empties the s2 bucket** (`mc rm --recursive`) before restarting the s2 pod.

This is implemented as a `reset_state(mode)` function with a per-mode branch. Reset time target: ~10–15s (vs ~10 min for a cluster cycle).

**Manifest change:** add the `rm -rf /data/*` initContainer to `gke/durable-streams.yaml` (and the ursula manifest). No durable-streams source code change is required (decided: pod-restart over an in-place reset endpoint).

---

## 6. Clusters: persistent, per-mode, parallel, deferred teardown

- **One cluster per mode** (`bench-wal`, `bench-ursula`, `bench-s2`), each in its own zone within the suite's region. A full cluster runs one server at a time, so mode-level concurrency = separate clusters.
- `bench … run` calls `cluster-up` per mode only if the cluster is absent (idempotent). The three mode-sweeps run **in parallel**, each on its own cluster, each with an isolated `KUBECONFIG` to avoid the concurrent-`get-credentials` race.
- **Clusters persist between experiments.** Teardown is a deliberate, separate step (`bench … teardown`) — never automatic. A long-timer safety-net (e.g. background delete after N hours) guards against forgotten clusters.
- **wal is the only durable config** benchmarked (no strict / strict-iouring / cache variants — those were settled this session: strict's per-stream fsync cliffs, the tail cache is marginal).
- The three clusters currently up (`bench-durable`, `bench-ursula`, `bench-s2`) can be renamed/reused to seed this, or torn down and respun fresh.

---

## 7. Report generation

`scripts/report.py <suite.json>` reads each mode's `cells.json` (the same file the walker writes during `run`, §4.2) plus the per-cell `merged.json` and emits **aggregated data + a markdown skeleton** (the chosen scope — the human writes the narrative on top):

**Outputs (under `results/<suite>/`):**

1. `aggregate.csv` / `aggregate.json` — one row per `(mode, stream_count)`: pinned pods, throughput (median of confirm reps), p99, saturated?, reason/status.
2. `report.md` — a skeleton with:
   - A **write-throughput table** (stream_count × mode → ops/s @ pinned pods, with a marker for `saturated:false` / `error` cells).
   - A **cross-mode comparison** (durable:wal vs ursula vs s2; matched-durability multiples).
   - A **per-cell detail** section (the saturation walk: pods → throughput at each rung) so the curve is inspectable.
   - Empty **"Findings"** / **"Caveats"** headers for the human to fill.

The report is **deterministically regenerable** (`bench … report`) from the raw results with no cluster running.

---

## 8. SSE and replay (clarifications only — not redesigned)

- **SSE** stays exactly as-is. It is fan-out delivery latency on one stream with one driver pod; there is no saturation search and today's numbers are good (durable:wal sub-ms–5ms; s2 ~52ms). No change.
- **Replay** is **not broken.** Its `thr=0` is *expected*: catch-up replay is a one-shot **latency** workload, so throughput is N/A and only p99 is meaningful. The redesign documents this so it stops being mistaken for a failure. No mechanism change.

These are noted so the runbook covers all three test classes, but only write-throughput gets the new saturation machinery.

---

## 9. Files

**New:**
- `scripts/bench` — driver (parses suite JSON; `run`/`report`/`teardown`; per-mode parallel orchestration; cluster state file).
- `scripts/lib-saturate.sh` — the per-`(mode, stream_count)` ladder walker (§4), reusing `lib-bench.sh` functions.
- `scripts/report.py` — aggregation + markdown skeleton (§7).
- `suites/write-throughput.json` — the example/default suite.
- `docs/RUNBOOK.md` — copy-pasteable agent guide: prerequisites, `cluster-up`, `bench run`, resume/state-clear behavior, report, deferred `teardown`, and the per-mode parallelization strategy.

**Modified (reuse):**
- `gke/durable-streams.yaml`, ursula manifest — add the `rm -rf /data/*` initContainer.
- `scripts/lib-bench.sh` — extract/expose the functions the walker calls (deploy, fleet, collect, merge); add `reset_state(mode)` (§5). The walker writes/reads the per-mode `cells.json` directly (no `pins.py`).
- `scripts/saturation.py`, `cluster-up.sh`, `gke/bench-job.yaml`, `gke/minio.yaml` — reuse as-is.

**Dropped:** `scripts/pins.py` / `pins.json` — superseded by the per-mode `cells.json` results-and-state file (§4.2).

**Unchanged:** the SSE/replay paths in `gke-bench.sh` (kept for those test classes).

---

## 10. Known risks

- **100k creation-choke.** At ~200–300 concurrent pods, `PUT /v1/stream` drops connections, so 100k cells fail before saturating. The walker records these as `status="error"` rather than a fake ceiling. Honestly resolving 100k throughput likely needs either a server-side fix to concurrent stream creation, staggered creation in the client, or accepting a documented lower bound. **This is the primary open risk and the report must not hide it.**
- **`cpu_pct` unreliable > ~10k streams.** Mitigated by using throughput-plateau as the primary saturation signal; CPU is secondary/confirmatory only.
- **MinIO coupling.** MinIO is both the HDR-result store and (for s2) the object tier; it needs ≥2–4 CPU at high pod counts or result collection corrupts. The suite's MinIO request must scale with `client_nodes`.

---

## 11. Success criteria

1. `bench suites/write-throughput.json run` brings up three persistent clusters, finds the saturating pod count per `(mode, stream_count)` via the ladder, and writes `aggregate.csv` + `report.md` — with no manual cluster babysitting.
2. Re-running after an interruption resumes only unsolved cells; saturated cells are skipped.
3. `bench … teardown` removes exactly the suite's clusters and nothing else.
4. Each pinned throughput is a **real ceiling** (the next ladder rung gave <`plateau_pct` more), or is explicitly marked `saturated:false` / `error`.
5. An agent can run the whole thing from `docs/RUNBOOK.md` without prior context.
