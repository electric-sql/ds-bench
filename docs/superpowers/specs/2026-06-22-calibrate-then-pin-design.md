# Calibrate-then-pin benchmarking — design

**Date:** 2026-06-22
**Status:** approved design, pre-implementation

## Problem

The phase runners (`gke-rawpower.sh`, `gke-scaleout.sh`, `gke-sustained.sh`) size
client load with a **headroom-guard bump loop** in `lib-bench.sh:run_cell`: start
at `INIT_PARALLELISM` pods, run the cell, double the pods until the server
saturates or `MAX_PODS`/`MAX_BUMPS` is hit. Saturation is judged **only** by
`server CPU ≥ 90%×cores` (`headroom_verdict`, lib-bench.sh:212).

Two consequences, both observed on the 2026-06-22 c4d run:

1. **Wrong signal for fsync-bound workloads.** Appends / multi-stream with small
   payloads are fsync-latency-bound, not CPU-bound — the server hits its
   throughput ceiling at ~55% CPU (we saw 222% of a 400% budget). The guard sees
   "CPU < 90% → keep bumping", never crosses the CPU threshold, hits `MAX_BUMPS`,
   and mislabels a genuinely saturated cell as `client_capped`. Every cell in the
   run came back `client_capped`; the extra pods only inflated p99 (1.8 → 12.8 ms)
   while throughput was flat.

2. **Per-run bump variance.** Each cell re-runs up to `MAX_BUMPS+1` times on the
   same warm server (cache/disk/compaction drift), doubling brackets the peak
   coarsely, and it is slow and costly.

## Goal

Separate **finding the operating point** (calibration) from **measuring at it**
(measurement):

- A **calibration** records, per cell, the smallest pod count that reaches ~peak
  throughput (the "knee"), using a corrected saturation rule.
- Calibrations are **pinned to the server image** (plus machine + CPU/mem) and
  committed, so a new image forces a fresh calibration — unless the developer
  deliberately reuses a prior one.
- Measurement runs at the **fixed pinned pod count × REPEATS** — reproducible,
  cheap, no bump variance.

## Decisions (from brainstorming)

- **Calibration key** = `server-image-digest + machine + cpu + mem`.
- **Missing/stale by default** → **fail fast** (do not silently guess).
- **Reuse** of a previous system's calibration is **opt-in** via
  `REUSE_CALIBRATION=latest` (newest pins matching machine+cpu+mem, ignoring the
  image digest). Reports flag every reused cell as an image mismatch.
- **Storage** = a single committed `calibration/pins.json`.
- **Saturation rule** = `server_bound` if `CPU ≥ 90%×cores` **OR** doubling pods
  yields `< 10%` more throughput; **pin the knee** (the smaller pod count that
  already had ~peak).
- **Mechanism** = a `MODE` toggle inside `lib-bench.sh:run_cell`; phase scripts
  stay unchanged thin matrices (approach A).

## Architecture

```
phase scripts (rawpower/scaleout/sustained)  — unchanged thin matrices
        │  call run_cell <cell> <bench_cmd> ...
        ▼
lib-bench.sh
  ├─ run_cell — branches on $MODE
  │     calibrate: bump loop + saturation rule → record knee → pins.py set
  │     measure  : pins.py get (or REUSE=latest) → fixed pods × REPEATS, or fail
  ├─ saturation_check  — CPU≥90%×cores OR <10% throughput gain vs prev bump
  ├─ server_image_digest — from the running pod's containerStatuses imageID
  └─ coordinator/fleet fetch — retry-until-Running guard (no fatal kubectl race)
        │
        ▼
scripts/pins.py  — calibration/pins.json CRUD (get / set / latest / list)
        │
        ▼
calibration/pins.json   (committed)
```

### Key derivation

After the server Deployment is up, read the **running pod's** image digest:
`kubectl … containerStatuses[0].imageID` → `…@sha256:<hex>`; take the first 12
hex chars. (Reflects what actually ran; works on kind and GKE.)

```
key = "<digest12>-<machine>-cpu<N>-mem<M>"
```
- `machine` = `SERVER_MACHINE` (`kind` for local), `N` = `SERVER_CPUS`,
  `M` = `SERVER_MEM`.
- A new image → new digest → new key → absent from `pins.json` → fail fast
  (unless `REUSE_CALIBRATION=latest`). This is the "redo on a new image" trigger.

### pins.json schema

```json
{
  "c105b202e5b3-c4d-standard-16-lssd-cpu4-mem16Gi": {
    "seq": 7,
    "image": "sha256:c105b202e5b3...",
    "machine": "c4d-standard-16-lssd",
    "server_cpu": "4",
    "server_mem": "16Gi",
    "cells": {
      "ms-cpu4-n100": { "pods": 32, "saturated": true,  "reason": "plateau", "ops": 1069919 },
      "ms-cpu4-n10":  { "pods": 16, "saturated": true,  "reason": "plateau", "ops": 860827 },
      "reads-cpu4-size1024-conn256": { "pods": 16, "saturated": true, "reason": "cpu" }
    }
  }
}
```

- `seq` — monotonic integer assigned on calibrate (`max(existing seq)+1`). It is
  the recency signal `REUSE_CALIBRATION=latest` orders by, so "latest" is
  unambiguous and independent of file ordering (no timestamps → clean diffs).
- `reason` ∈ `cpu | plateau | max_pods`. `saturated:false` + `reason:"max_pods"`
  records an honest **lower-bound** pin when a cell never saturated.
- `ops` — calibrated throughput at the pinned pods (provenance/reference only).

## Components

### 1. `scripts/pins.py` (new)

Owns `calibration/pins.json`. Subcommands (pure, no cluster, unit-testable):

- `get <key> <cell>` → prints pods, exit 0; exit non-zero if key or cell absent.
- `set <key> <cell> <pods> --reason R --ops N [--meta image=… machine=… cpu=… mem=…]`
  — creates/updates the key (assigning `seq` on first touch) and the cell entry,
  preserving all other keys/cells. Stable key ordering + 2-space indent for clean
  diffs.
- `latest <machine> <cpu> <mem>` → prints the key with the highest `seq` whose
  machine+cpu+mem match (ignoring digest); exit non-zero if none.
- `list` → human-readable summary.

Python (consistent with `render_common.py` et al.; avoids a `jq` dependency).

### 2. `lib-bench.sh` changes

- **`saturation_check`** — given the bump history `(pods, throughput, cpu_pct)`,
  return `server_bound|server_headroom` and a `reason`:
  - `cpu` if `cpu_pct ≥ 90%×cores`;
  - `plateau` if a previous (half-pods) data point exists and
    `(thr - prev_thr)/prev_thr < 0.10`;
  - else `server_headroom`.
  Throughput is read from each iteration's `merged.json`
  (`aggregate_ops_per_sec` or `aggregate_events_per_sec`).
- **`run_cell` branch on `$MODE`** (default `measure`):
  - **calibrate**: run the bump loop with `saturation_check`; on `plateau` pin the
    **knee** (the pre-doubling pods); on `cpu` pin the current pods; on
    `MAX_PODS/MAX_BUMPS` pin current pods with `saturated:false reason:max_pods`.
    `pins.py set` the result. Forces `REPEATS=1` (knee-finding, not measurement;
    overridable).
  - **measure**: resolve pin via `pins.py get <key> <cell>`; if absent and
    `REUSE_CALIBRATION=latest`, resolve via `pins.py latest <machine> <cpu> <mem>`
    and mark provenance mismatch; if still unresolved → **fail fast**. Run **fixed**
    at the pinned pods × `REPEATS`, no bump loop.
- **`server_image_digest`** helper (above).
- **Coordinator/fleet fetch guard** — before fetching coordinator output, wait for
  its pod container to be `Running`/`Completed` (bounded retry); never let a
  `ContainerCreating` `BadRequest` abort under `set -e`. (This is the race that
  killed the 2026-06-22 run at `rc=1`.)

### 3. Provenance + reports

Each cell's `verdict.txt` records: `calibration_key`, `calibration_image`,
`running_image`, `calibration_matched` (bool), plus the existing `parallelism`,
`server_cpu_pct`, and the cell `reason`/`saturated`.

`gen-report.py` / `render_common.py` surface, per cell:
- **what capped it** — `reason` (`cpu`/`plateau`/`max_pods`) and `saturated`;
- **calibration provenance** — `matched` vs `reused-from <old-digest>` (image
  mismatch).

So the report makes "what capped the results, and on whose calibration" explicit,
and the developer decides whether to recalibrate.

### 4. Phase scripts

Unchanged. They inherit `MODE` / `REUSE_CALIBRATION` from the environment and call
`run_cell` exactly as today, so calibrate and measure traverse the identical cell
set (cell keys always line up with pins).

## Workflow

```bash
# after building a new server image:
MODE=calibrate DS_TARGET=remote … scripts/gke-scaleout.sh slow   # → commits calibration/pins.json
git add calibration/pins.json && git commit

# measurement (default): pinned, reproducible
DS_TARGET=remote … scripts/gke-scaleout.sh slow

# reuse a previous system's calibration on a new build:
REUSE_CALIBRATION=latest DS_TARGET=remote … scripts/gke-scaleout.sh slow
#   → runs pinned from the newest same-machine/cpu calibration; report flags mismatch
```

## Error handling / edge cases

- **measure, no pin + no reuse** → exit non-zero:
  `no calibration for <key> [cell <c>]; run MODE=calibrate or set REUSE_CALIBRATION=latest`.
- **REUSE=latest, no same-machine/cpu calibration** → fail fast with that reason.
- **calibrate never saturates** → `saturated:false reason:max_pods`; measurement
  runs but carries the lower-bound flag into the report.
- **missing `samples.csv`** (no CPU reading) → plateau-only saturation for that
  cell, warn.
- **kubectl races** (coordinator/fleet) → bounded retry, non-fatal.

## Testing (TDD)

- **`pins.py`** — unit tests: get/set round-trip, missing-key exit codes,
  `latest` ordering by `seq`, set preserves unrelated keys/cells, stable output.
- **`saturation_check` / knee** — extract as a pure function; feed synthetic
  `(pods, throughput, cpu)` sequences and assert `reason` + pinned pods. Seed
  cases from the **real samples already on disk** (`results/scaleout/
  scaleout-slow-1782133067-64105/ms-cpu4-n10|n100`).
- **End-to-end** — local-kind `MODE=calibrate` then `MODE=measure` smoke
  (cheap, no cloud); assert a pin is written then consumed, and a forced digest
  change triggers fail-fast / reuse.
- Coordinator-fetch fix — covered by the local smoke + review (kubectl-dependent).

## Out of scope

- Auto-recalibration triggers (developer decides from the report).
- Changing the cell matrices themselves.
- Multi-node / non-durable-streams systems (ursula/s2) calibration — same
  mechanism applies but is not part of this change.

## Decisions left at sensible defaults (changeable in review)

- `pins.json` lives in a `calibration/` dir, not repo root.
- `MODE=calibrate` forces `REPEATS=1` (overridable); `measure` uses normal
  `REPEATS`.
