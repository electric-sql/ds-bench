# Phase 1 — DS raw power (uncapped single-stream micro) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development.
> Steps use checkbox (`- [ ]`) syntax.

> **SUPERSEDED (2026-06-19): JSON dropped from all phases.** The byte-vs-JSON study and
> every `json-single`/`json-array` reference below are no longer run — bytes (binary) only,
> with `--splice-appends` as the large-payload path. Rationale: bytes is the realistic best
> case and is splice-eligible (zero-copy); JSON only adds client-side encoding the server
> benchmark doesn't need to chase. The `--body-mode` capability stays in `ds-bench` (binary
> default, JSON unused). Append cells are now `binary` × conn × payload only.

**Goal:** Reproduce the durable-streams `BENCHMARKS.md` single-stream studies (reads,
appends, byte-vs-JSON, splice, cold-tier, single-stream fan-out) on modern NVMe hardware,
**uncapped** — scaled so the SERVER is the bottleneck, not the load generator (their
published run was capped by a 3-core `wrk`). DS-only (raw power). Server CPU/RSS from the
metrics sidecar (replacing their cgroup `CPUUsageNSec`). **fast** and **slow** profiles.

**Architecture:** Load comes from the decoupled `ds-bench` fleet (k8s Indexed Job on
`role=client`, scaled until server-bound); the server runs on a modern NVMe node with a
parametrized CPU budget (2/4/8/16) and the metrics sidecar. New fleet workloads
(`reads.rs`, `append.rs`) replicate autobench's single-stream read/append studies at the
protocol level; `fanout.rs` (existing) covers single-stream fan-out. A headroom-guarded
runner sweeps the matrix per profile; a renderer emits BENCHMARKS.md-style tables.

**Tech Stack:** Rust (edition 2024), tokio/reqwest/hdrhistogram, bash, python3, k8s, Cloud Build.

## Global Constraints
- **Uncapped / server-bound:** every throughput number is valid ONLY when the server is
  the bottleneck — server CPU near 100%×(its cores) AND client pods show CPU slack. The
  runner scales client pods until this holds, records client headroom, and FLAGS any cell
  where the client saturated (the BENCHMARKS.md failure we're fixing).
- **Server CPU/RSS via the metrics sidecar** (`deploy/metrics/poller.sh`), not cgroup
  `CPUUsageNSec`. CPU% = Δcpu_ticks/CLK_TCK/elapsed×100 over the measured window.
- **Forked files stay byte-identical** (`common.rs`,`backend.rs`,`bootstrap.rs`,`fanout.rs`,
  `multi_stream.rs`). New workloads are NEW modules. `fanout.rs` is RUN as-is (not edited).
- **Two profiles:** `fast` (server 2 cpu, size 1K, conn 256, short, 1 repeat) and `slow`
  (cores {2,4,8,16} × sizes {1K,16K,1M} × conn {16,64,256,1024}, byte+JSON, splice,
  cold-tier, longer, 3 repeats + median/cv). A `PROFILE` env selects.
- **Modern NVMe hardware:** server on a GKE node with local NVMe SSD (`role=server`,
  `--ephemeral-storage-local-ssd`); the server's CPU budget is set per core-scaling cell.
- **GKE safety:** every kubectl `--context gke_vaxine_europe-west1-b_ds-bench -n ds-bench`,
  never prod; Cloud Build (amd64). Server = `durable-streams:dev` (current `1e9423dc`).
- Branch off `main`; commit per task; cluster RUNS are integration gates.

## File Structure
```
ds-bench/src/
├── reads.rs          # NEW: sustained hot catch-up reads, size × conn
├── append.rs         # NEW: single stream, N concurrent appenders, conn; binary/JSON mode
├── main.rs / lib.rs  # MODIFY: register `reads` + `append`
gke/
├── durable-streams.yaml   # MODIFY: parametrize CPU budget ${SERVER_CPUS_LIMIT}; sidecar already added
scripts/
├── gke-rawpower.sh   # NEW: profile-driven, headroom-guarded matrix runner (core-scaling + size/conn + fan-out)
└── render-rawpower.py# NEW: BENCHMARKS.md-style tables (reads by size/conn, scaling-by-cores, appends, byte/JSON, splice, cold, fan-out)
```

---

### Task 1: `reads` workload (sustained hot catch-up reads)

**Files:** Create `ds-bench/src/reads.rs`; modify `main.rs`/`lib.rs`.

**Interfaces:** Reuses `backend.rs`/`--api-style` + `dist::emit_hdr`. Read
`catch_up.rs` (one-shot replay) and `multi_stream.rs` (concurrency/HDR pattern) to match
idioms. `reads` is a SUSTAINED hot read: a pre-seeded resident stream is GET-read in a loop.

- [ ] **Step 1: Write `reads.rs`.** Args: `--target`, `--api-style`, `--stream` (pre-seeded),
  `--read-size-bytes R`, `--connections C` (per-pod concurrent readers), `--duration-secs`,
  `--seed-bytes` (total stream size to seed once at start). Setup: PUT + seed the stream to
  `--seed-bytes` of `R`-sized records (idempotent; only pod 0 seeds, others wait — or each
  reads a shared pre-seeded stream named by `--stream`). Steady state: `C` concurrent tasks
  loop `GET ?offset=...` reading `R` bytes (hot/resident catch-up reads, the `sendfile` path),
  recording per-read latency into a shared HDR. End: `emit_hdr(&hist,&format!("reads-{}",pid))`
  + JSON summary (`scenario:"reads"`, `aggregate_ops_per_sec`, `bytes_per_sec`, p50/p99/p999,
  read_size, connections). Match the read mechanics of `catch_up.rs` (don't invent).
- [ ] **Step 2: register** `reads` in `main.rs`+`lib.rs` (mirror `catch-up`).
- [ ] **Step 3: Verify** — `cargo build --release`; `ds-bench reads --help`; forked files unchanged (`git status`).
- [ ] **Step 4: Commit** — `feat(ds-bench): reads workload (sustained hot catch-up reads, size x conn)`.

---

### Task 2: `append` workload (single-stream concurrent appenders + byte/JSON mode)

**Files:** Create `ds-bench/src/append.rs`; modify `main.rs`/`lib.rs`.

**Interfaces:** ONE stream, `C` concurrent appenders (the group-commit story — distinct
from `multi_stream`'s N-streams). Read `multi_stream.rs` for the writer/HDR pattern.

- [ ] **Step 1: Write `append.rs`.** Args: `--target`, `--api-style`, `--stream`,
  `--connections C`, `--payload-bytes`, `--duration-secs`, `--body-mode {binary|json-single|json-array}`,
  `--array-records N` (for json-array). `C` concurrent tasks POST to the SAME stream as fast
  as possible (concurrency drives group commit), recording append latency into a shared HDR.
  **Body mode:** binary = raw bytes (current durable backend default); `json-single` = a JSON
  value body; `json-array` = an N-record JSON array (the server flattens → records). Confirm
  whether `backend.rs` already sends a content-type/body the server treats as binary vs JSON;
  if the durable backend has no JSON-body path, add a minimal body-mode switch HERE (in
  `append.rs`, building the request body + content-type) WITHOUT editing `backend.rs` — call
  the backend's raw-append with the chosen body/content-type, or add a small helper in this
  module. END: `emit_hdr("append-{pid}")` + summary (`scenario:"append"`, `aggregate_ops_per_sec`,
  for json-array also `records_per_sec`, p50/p99/p999, connections, body_mode).
- [ ] **Step 2: register** `append` in `main.rs`+`lib.rs`.
- [ ] **Step 3: Verify** — `cargo build`; `ds-bench append --help` (incl. `--body-mode`); a
  unit test that `json-array` builds a valid N-record JSON body; forked files unchanged.
- [ ] **Step 4: Commit** — `feat(ds-bench): append workload (single-stream concurrent appenders, binary/JSON body modes)`.

---

### Task 3: Parametrize the server CPU budget (core-scaling)

**Files:** Modify `gke/durable-streams.yaml`.

- [ ] **Step 1:** Make the server container's CPU `requests`+`limits` an envsubst var
  `${SERVER_CPU}` (e.g. `requests.cpu: ${SERVER_CPU}`, `limits.cpu: ${SERVER_CPU}`), so the
  runner can deploy the server at 2/4/8/16 cores per scaling cell. Keep the NVMe `/data`
  emptyDir, the `--tier off` (local-durable, matched to BENCHMARKS.md), and the metrics
  sidecar. The server should use the cores it's given (the raw engine is multi-threaded;
  the CPU limit bounds it — confirm the binary respects the cgroup, else pass a `--threads`/
  worker count = `${SERVER_CPU}`).
- [ ] **Step 2: Verify** — `envsubst` with `SERVER_CPU=2` renders valid YAML (`yaml.safe_load_all`).
- [ ] **Step 3: Commit** — `feat(gke): parametrize server CPU budget for core-scaling`.

---

### Task 4: `gke-rawpower.sh` — profile-driven, headroom-guarded matrix runner

**Files:** Create `scripts/gke-rawpower.sh`.

**Interfaces:** `gke-rawpower.sh [fast|slow]` runs the Phase-1 matrix for DS-rust and
collects merged HDR + sidecar CPU/RSS per cell into `results/rawpower/<RUN_ID>/<cell>/`.

- [ ] **Step 1: Write it** (model on `gke-sustained.sh` for CTX/`K()`/RUN_ID/fleet→coordinator
  merge + the metrics-poller ConfigMap + sidecar `samples.csv` collection + per-cell CSV reset).
  Define the matrix per PROFILE:
  - `fast`: SERVER_CPU=2; reads {size 1K × conn 256}; append {conn 256, binary}; fan-out {subs 256}; duration short (~15s); 1 repeat.
  - `slow`: SERVER_CPU ∈ {2,4,8,16}; reads {1K,16K,1M} × {16,64,256,1024}; append {64,256} × {binary, json-single, json-array(10)} + a `--splice-appends` server variant at 1MB binary; fan-out subs {1,10,100,1000}; cold-tier read (deploy server with `--tier local`, seed > hot cap, read cold); duration ~30s; 3 repeats (record each; renderer takes median/cv).
  For each cell: deploy/scale the server at `SERVER_CPU` (envsubst `gke/durable-streams.yaml`), wait-serving (reuse the readiness probe); reset the sidecar CSV; launch the fleet workload (`reads`/`append`/`fan-out`) with the cell's flags, scaling `PARALLELISM` (client pods) UP until **server-bound** — i.e., poll the sidecar: if server CPU < ~90%×SERVER_CPU and the run isn't error-bound, increase pods and re-run (bounded retries); record the final client headroom; coordinator-merge; collect `merged.json` + `samples.csv`.
- [ ] **Step 2: the headroom guard** — implement the "scale pods until server-bound" loop with a cap (e.g. ≤ N client nodes); if the server still isn't saturated at the cap, record `client_capped=true` for that cell (do NOT silently report a capped number — flag it, exactly the BENCHMARKS.md problem we're fixing).
- [ ] **Step 3: Verify** — `bash -n`; dry-run the matrix expansion for `fast` (echo the cells). Integration gate (cluster): `scripts/gke-up.sh && scripts/gke-rawpower.sh fast` → `results/rawpower/<id>/` has a reads + append + fan-out cell with non-zero merged + a samples.csv, and a recorded headroom verdict.
- [ ] **Step 4: Commit** — `feat(phase1): gke-rawpower.sh — profile-driven headroom-guarded matrix runner`.

---

### Task 5: `render-rawpower.py` — BENCHMARKS.md-style report

**Files:** Create `scripts/render-rawpower.py`.

- [ ] **Step 1: Write it** — read `results/rawpower/<RUN_ID>/<cell>/{merged.json,samples.csv}`;
  emit `report.md` mirroring `BENCHMARKS.md`'s tables: **Reads** (size × conn → throughput +
  server CPU% + p99), **Read scaling by server cores** (cores → throughput + CPU%), **Appends**
  (conn → throughput + CPU% + p99), **byte vs JSON** (mode → appends/s + records/s + CPU%),
  **splice** (CPU lever), **cold-tier read** (GB/s), **single-stream fan-out** (subs → delivery
  p99 + events/s). Server CPU% from `samples.csv` (Δticks math). For `slow`, show median + cv
  across the 3 repeats. Mark any `client_capped` cell explicitly.
  Disclosures: modern NVMe (not their Xeon), server CPU from sidecar (not cgroup), uncapped
  (server-bound) — note where we exceeded their client-capped figures.
- [ ] **Step 2: Verify** — run on a hand-made sample cell dir (merged.json + samples.csv) → report.md with the sections, no crash; partial data → `-`.
- [ ] **Step 3: Commit** — `feat(phase1): render-rawpower.py — BENCHMARKS.md-style raw-power report`.

---

## Cluster run (integration gate — after the codeable tasks)
- Push `ds-bench:dev` (Cloud Build) with the new `reads`/`append` workloads.
- `scripts/gke-up.sh` (server pool with NVMe; client pool scalable for the fleet) → `gke-rawpower.sh fast` (validate) → `gke-rawpower.sh slow` (the real matrix) → `render-rawpower.py` → tear down.

## Self-Review
- **Coverage** of BENCHMARKS.md single-stream studies: reads (T1) ✓, appends + byte/JSON (T2) ✓,
  core-scaling (T3+T4) ✓, splice + cold-tier (T4 matrix) ✓, single-stream fan-out (existing
  `fanout.rs`, run by T4) ✓, server CPU (sidecar) ✓, fast/slow profiles (T4) ✓.
- **Uncapped:** the headroom guard (T4 S2) is the core differentiator vs their capped run.
- **Forked files:** `fanout.rs`/`multi_stream.rs` only READ/RUN, not edited; new modules only.
- **Profiles:** `fast` = 2-cpu server + minimal cells (per the user); `slow` = full matrix.
- **Placeholders:** Rust boilerplate delegated to "match `catch_up.rs`/`multi_stream.rs`";
  novel logic (sustained read loop, single-stream concurrent append, body modes, the
  headroom-scaling loop, the CPU%-from-sidecar math) specified.
</content>
