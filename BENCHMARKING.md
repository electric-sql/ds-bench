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

| Phase | Script | What it measures |
|---|---|---|
| **1 — raw power** | `scripts/gke-rawpower.sh` | reads × size × conn, appends (bytes only) × conn × payload, fan-out × subs, splice, cold-tier — vs SERVER_CPU {2,4,8} |
| **2 — scale-out** | `scripts/gke-scaleout.sh` | multi-stream writes (sweep N streams) + multi-fanout (M×S) |
| **3 — sustained** | `scripts/gke-sustained.sh` | steady load over time → server **RSS drift / memory stability** + throughput/p99 vs stream count |

The engine (deploy server, run client fleet, merge HDR results, headroom guard,
sidecar metrics) is shared in **`scripts/lib-bench.sh`**; each phase script is just
its matrix. Target selection (context, image refs, node selectors) is in
**`scripts/target-env.sh`**. Renderers turn the raw result dirs into Markdown tables.

### `DS_TARGET`

```bash
export DS_TARGET=local      # kind cluster, locally-built images, single node (default)
export DS_TARGET=remote     # GKE, Artifact Registry images, role=server/client pools
```

Optional: `KIND_CLUSTER` (default `ds-bench`); for remote, `PROJECT`/`ZONE`/`CLUSTER`
(defaults: gcloud project / `europe-west1-b` / `ds-bench`).

### Where things land

- Raw per-cell data: `results/{rawpower,scaleout,sustained}/<run-id>/<cell>/...`
  (`merged.json` = merged HDR/throughput, `samples.csv` = server RSS/CPU, `verdict.txt`).
- Rendered phase reports + the combined report: `docs/` (you write these in step 6).

---

## 1. Prerequisites

**Local (`DS_TARGET=local`):** Docker running, `kind`, `kubectl`, `envsubst` (gettext),
`python3`. A clone of the server at `../durable-streams`. Nothing in the cloud, no billing.

**Remote (`DS_TARGET=remote`):** `gcloud` authenticated with access to the project, plus
`kubectl`/`envsubst`/`python3`. Images build via Cloud Build (amd64).

> Local builds are **native arch** (`docker build` + `kind load`) — fast, no QEMU, no
> registry. Remote builds go through Cloud Build → Artifact Registry.

---

## 2. Build images

```bash
export DS_TARGET=local        # or remote
scripts/build-images.sh
```

Builds `ds-bench:dev` (workload client) and `durable-streams:dev` (server, from the
**current `../durable-streams` checkout**). Iterating on the server? `git -C
../durable-streams checkout <branch>` then re-run this — that is the inner dev loop.

## 3. Cluster up

```bash
scripts/cluster-up.sh
```

Creates the cluster (kind single node / GKE server+clients pools), the `ds-bench`
namespace, the `metrics-poller` ConfigMap, and MinIO (the object tier + the HDR-merge
store). Idempotent.

## 4. Run the phases

Same commands for local and remote. Each phase has a **`fast`** profile (one small
point — smoke) and a **`slow`** profile (the full matrix).

```bash
# Phase 1 — raw power
scripts/gke-rawpower.sh fast        # smoke: SERVER_CPU=2, one point per dim
scripts/gke-rawpower.sh slow        # full: CPU {2,4,8} × all dims

# Phase 2 — scale-out
scripts/gke-scaleout.sh fast
scripts/gke-scaleout.sh slow

# Phase 3 — sustained (system = durable; ursula/s2 are remote-only comparisons)
scripts/gke-sustained.sh durable sustained          # default stream sweep 10 50 100 150
scripts/gke-sustained.sh durable sustained 10 100   # custom stream counts
```

Each prints its results dir (`results/<phase>/<run-id>/`).

**Env knobs** (all phases): `PARALLELISM` (client pods per cell), `REPEATS`,
`MAX_BUMPS` (headroom-guard pod doublings; `0` = fixed parallelism), `FLEET_TIMEOUT`,
`COORD_TIMEOUT`. Phase 3 also: `SERVER_CPUS RATE DURATION SETUP_CONCURRENCY M S`.
Example, a quick fixed-load local run: `PARALLELISM=2 MAX_BUMPS=0 REPEATS=1 scripts/gke-rawpower.sh fast`.

> **Headroom guard / `verdict.txt`.** A cell is `server_bound` (trustworthy ceiling)
> only if the server consumed ≥90% of its CPU budget; otherwise `client_capped` (a
> lower bound — add client pods / `PARALLELISM` to push harder). The renderers mark this.

## 5. Render each phase

```bash
python3 scripts/render-rawpower.py  results/rawpower/<run-id>   > docs/phase1-report.md
python3 scripts/render-scaleout.py  results/scaleout/<run-id>   > docs/phase2-report.md
python3 scripts/render-sustained.py results/sustained/<run-id>  > docs/phase3-report.md
```

(Run a renderer with no newer args to print to stdout; redirect to a file to keep it.)

## 6. Combined report

Assemble one document from the three phase reports so two clusters compare directly.
Include, at the top, the run context so it is reproducible:

- `DS_TARGET`, cluster shape (local kind single node / GKE n2d-standard-8 + clients),
  server commit (`git -C ../durable-streams rev-parse --short HEAD`), date, profiles run.
- Phase 1 headline: reads/s vs SERVER_CPU (scaling), append throughput, fan-out p99.
- Phase 2: multi-stream writes/s vs N, multi-fanout events/s + p99.
- Phase 3: **RSS start→end / drift** (flat = no leak), throughput/p99 vs N.
- Honesty notes: which cells are `client_capped` (lower bounds), object tier =
  in-cluster MinIO (not cloud S3), 1 vs 3 repeats.

Suggested path: `docs/combined-report-<target>-<date>.md`. To compare local vs cloud,
produce one per target and diff the headline tables.

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

## 7. Tear down

```bash
scripts/cluster-down.sh
```

Local: `kind delete cluster`. **Remote: deletes the GKE cluster, verifies it is gone (no
billing), unsets the context — always run this after a cloud run.**

---

## One-shot (local smoke)

```bash
export DS_TARGET=local
scripts/build-images.sh && scripts/cluster-up.sh
PARALLELISM=2 MAX_BUMPS=0 scripts/gke-rawpower.sh fast
python3 scripts/render-rawpower.py results/rawpower/$(ls -t results/rawpower | head -1)
scripts/cluster-down.sh
```
