# Benchmark suite — Tier A (raw single-node) + Tier B cleanup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce shareable RAW single-node Rust DS numbers by porting the `autobench`
suite into `micro/` and running it in-cluster on a dedicated NVMe node, and clean up
the cross-system macro results (raw renderer, clean preset sweep, fan-out diagnostic).

**Architecture:** `micro/` = ported `autobench` (shell + wrk + python), run via a
dedicated-node privileged k8s Job (Option A: server + `wrk` co-located, faithful to
autobench's isolation). `ds-bench` Tier-B cleanup adds a DS-rust-only renderer + a
sole-mutator preset-sweep script. Images via Cloud Build (amd64). Results land in
MinIO, pulled to `results/`.

**Tech Stack:** bash, wrk, python3, Rust (DS server), Docker/Cloud Build, kubectl, MinIO/`mc`.

## Global Constraints

- **GKE safety:** every kubectl uses `--context gke_vaxine_europe-west1-b_ds-bench -n ds-bench`.
  NEVER a bare kubectl or any other `gke_vaxine_*` (prod) context. The cluster is
  currently **torn down** — bring up with `scripts/gke-up.sh` before any in-cluster run.
- **Images via Cloud Build, NOT QEMU buildx:** `cp <dockerfile> <ctx>/Dockerfile &&
  gcloud builds submit <ctx> --tag europe-west1-docker.pkg.dev/vaxine/ds-bench/<name>:dev && rm <ctx>/Dockerfile`.
- **Hardware:** server-under-test + `wrk` on the NVMe `role=server` node; data on NVMe
  `emptyDir`; object tier = in-cluster MinIO on NVMe. Record host/kernel/cpu/governor/commit in `meta.txt`.
- **Matched durability + honesty disclosures** carried from the spec
  (`docs/superpowers/specs/2026-06-18-benchmark-suite-design.md`): every rendered
  report states single-node, disk substrate, per-system caveats.
- **ds-bench forked files stay measurement-identical:** `common.rs`/`backend.rs`/`bootstrap.rs`
  byte-identical to upstream; `fanout.rs`/`multi_stream.rs` carry only the one additive
  `emit_hdr` line. Tier-B tasks here touch only renderers/scripts, not those files.
- Branch off `main`; commit per task; DRY/YAGNI.

## File Structure

```
ds-rust-bench/
├── micro/                          # NEW: ported autobench (Tier A)
│   ├── run.sh  lib.sh  stop.sh  config.env  aggregate.py  README.md
│   └── studies/{engines,cpu_scaling,memory_cold,splice,tiering,json}.sh
├── dockerfiles/micro.Dockerfile    # NEW: builds DS server + bundles wrk/curl/python3 + micro/
├── gke/micro-job.yaml              # NEW: Option-A dedicated-node privileged Job
├── scripts/
│   ├── gke-micro.sh                # NEW: run Tier A in-cluster, collect+render
│   ├── render-raw.py               # NEW (Tier B): DS-rust-only raw report
│   └── gke-ursula-sweep.sh         # NEW (Tier B): sole-mutator clean preset sweep
├── docs/fan-out-outlier-diagnostic.md  # NEW (Tier B): the 916ms re-run procedure
└── results/{micro,raw}/            # outputs
```

---

## Tier A — raw single-node (`micro/`)

### Task 1: Port `autobench/` into `micro/`

**Files:** Create `micro/` (copy from `/Users/vbalegas/workspace/durable-streams-bench/autobench/`).

- [ ] **Step 1: Copy the suite.**
```bash
mkdir -p micro
cp -R /Users/vbalegas/workspace/durable-streams-bench/autobench/. micro/
```
- [ ] **Step 2: Make it k8s-friendly in `micro/lib.sh` — replace the `systemd-run`
  server launch with `taskset`** (no systemd in containers). Find `start_server()`'s
  `sudo systemd-run … "$BIN" …` and replace the launch with:
```bash
# k8s/container mode: no systemd. Pin to SERVER_CPUS via taskset; the Pod cgroup is the outer limit.
taskset -c "${SERVER_CPUS:-0-7}" "$BIN" --host 127.0.0.1 --port "$PORT" \
  --data-dir "$DATA" --http-engine "$engine" "$@" &
SERVER_PID=$!
```
  and `stop_server()` to `kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null || true`.
  For the **memory_cold** study's `MemoryMax` variation (which used cgroup limits):
  guard it behind `MEMCAP_CGROUP` — if a delegated child cgroup (`/sys/fs/cgroup/dsbench`)
  is writable, write `memory.max`; else run only the unbounded cell and log that the
  capped cells were skipped (do NOT silently drop — print `SKIP memory_cold cap=$cap (no cgroup delegation)`).
- [ ] **Step 3: Defaults for in-container paths** in `micro/config.env`: `BIN`
  defaults to `/usr/local/bin/durable-streams-server`, `DATA=/data` (the NVMe mount),
  `SR_DIR` unset (binary is pre-built into the image). Keep `PROFILE` (smoke/fast/full).
- [ ] **Step 4: Verify locally** (no server build needed):
  `bash -n micro/run.sh micro/lib.sh micro/studies/*.sh` (all pass);
  `printf '%s\n' '{"study":"engines","scenario":"append","engine":"raw","mode":"tail","size":100,"conn":256,"rep":1,"rps":1000,"p50_ms":1,"p99_ms":2,"max_ms":3,"cpu_pct":50,"server_cpus":"0-7"}' > /tmp/s.jsonl && python3 micro/aggregate.py /tmp/s.jsonl` produces a markdown table.
- [ ] **Step 5: Commit** — `git add micro && git commit -m "feat(micro): port autobench suite (taskset launch, container paths)"`.

### Task 2: `dockerfiles/micro.Dockerfile`

**Files:** Create `dockerfiles/micro.Dockerfile`.

- [ ] **Step 1: Write it** — build stage compiles the DS server; runtime bundles tools + `micro/` + binary:
```dockerfile
# build the durable-streams Rust server (amd64; Cloud Build provides native amd64)
FROM rust:1.86 AS build
WORKDIR /src
COPY . .
# the durable-streams source is the build context (see gke-micro.sh: context = ../durable-streams)
RUN cargo build --release --manifest-path packages/server-rust/Cargo.toml \
 && cp target/release/durable-streams-server /durable-streams-server

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl python3 wrk \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /durable-streams-server /usr/local/bin/durable-streams-server
COPY micro/ /micro/
WORKDIR /micro
ENV BIN=/usr/local/bin/durable-streams-server DATA=/data
ENTRYPOINT ["bash","run.sh"]
```
  NOTE: the build context must contain BOTH the durable-streams source AND `micro/`.
  Resolve in Task 4's script by assembling a context (copy `micro/` into the
  durable-streams checkout, or use a small staging dir). Document the chosen approach
  in the script; do not hardcode a cross-repo path in the Dockerfile.
- [ ] **Step 2: Verify** — `bash -n` n/a (Dockerfile); review that `wrk` is in
  bookworm (`apt-cache policy wrk` is unavailable offline → the Cloud Build in Task 4
  is the real gate). Confirm the manifest path matches the actual server crate
  location (check `/Users/vbalegas/workspace/durable-streams/packages/server-rust/Cargo.toml` exists).
- [ ] **Step 3: Commit** — `git add dockerfiles/micro.Dockerfile && git commit -m "feat(micro): Dockerfile (DS server + wrk/python micro suite)"`.

### Task 3: `gke/micro-job.yaml` — Option-A dedicated-node Job

**Files:** Create `gke/micro-job.yaml`.

- [ ] **Step 1: Write the Job** — owns the NVMe `role=server` node (full-node requests
  so nothing co-schedules), privileged for `drop_caches`, NVMe `emptyDir` at `/data`,
  uploads results to MinIO:
```yaml
apiVersion: batch/v1
kind: Job
metadata: { name: micro, namespace: ds-bench }
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      nodeSelector: { role: server }
      securityContext: { }
      containers:
      - name: micro
        image: europe-west1-docker.pkg.dev/vaxine/ds-bench/micro:dev
        imagePullPolicy: Always
        securityContext: { privileged: true }   # drop_caches
        env:
        - { name: PROFILE, value: "fast" }
        - { name: SERVER_CPUS, value: "0-5" }    # client/wrk on the rest
        - { name: CLIENT_CPUS, value: "6-7" }
        - { name: RUN_ID, value: "REPLACE_RUN_ID" }
        command: ["bash","-lc"]
        args:
        - |
          bash run.sh
          mc alias set local http://minio:9000 minioadmin minioadmin
          mc cp --recursive /micro/out/ "local/bench-results/micro-${RUN_ID}/"
        resources:
          requests: { cpu: "7", memory: "24Gi" }   # ~own the n2d-standard-8
        volumeMounts:
        - { name: data, mountPath: /data }
      volumes:
      - { name: data, emptyDir: {} }              # NVMe ephemeral on role=server
```
  (Bundle `mc` into the image too, or reuse the ds-bench image's `mc` via an init/sidecar.
  Simplest: add the `mc` install line to `micro.Dockerfile` runtime stage.)
- [ ] **Step 2: Verify** — `kubectl --context … -n ds-bench apply --dry-run=client -f gke/micro-job.yaml` (after RUN_ID substitution) parses; nodeSelector/requests pin to the server node. (Real run = Task 4 integration gate.)
- [ ] **Step 3: Commit** — `git add gke/micro-job.yaml && git commit -m "feat(micro): Option-A dedicated-node privileged Job"`.

### Task 4: `scripts/gke-micro.sh` — run + collect + render

**Files:** Create `scripts/gke-micro.sh`.

- [ ] **Step 1: Write it** — `set -euo pipefail`; CTX/ns constants; (a) assemble the
  Docker build context (stage `micro/` into a copy of `../durable-streams`, or a temp
  dir with both) and Cloud-Build-push `micro:dev`; (b) substitute a unique `RUN_ID`
  into `gke/micro-job.yaml`, apply, `wait --for=condition=complete job/micro --timeout=7200s`
  (autobench full ≈ 90 min; fast ≈ 30 min); (c) `mc cp` the `micro-$RUN_ID/` prefix from
  MinIO into `results/micro/$RUN_ID/`; (d) the suite already wrote `RESULTS.md` —
  echo its path. Every kubectl `--context "$CTX" -n ds-bench`.
- [ ] **Step 2: Verify** — `bash -n scripts/gke-micro.sh`. **Integration gate (cluster
  session):** `scripts/gke-up.sh && PROFILE=smoke scripts/gke-micro.sh` → `results/micro/<id>/RESULTS.md`
  exists with non-empty engine/append tables; then tear down. (Gated on a cluster — the
  cluster is currently down.)
- [ ] **Step 3: Commit** — `git add scripts/gke-micro.sh && git commit -m "feat(micro): gke-micro.sh end-to-end raw single-node run"`.

---

## Tier B — codeable cleanup

### Task 5: `scripts/render-raw.py` — DS-rust-only raw report

**Files:** Create `scripts/render-raw.py`.

- [ ] **Step 1: Write it** — read `results-gke/durable-*.json` + `sweep-durable-*.json`,
  emit `results/raw/durable.md`: a single-system view (write writes/s + p50/p99/p999;
  fan-out events/s + p99; catch-up MB/s + p99; mixed per-class; saturation curve), with
  the honesty disclosures block (single-node, MinIO-on-NVMe, 8-core). Reuse the metric
  extraction from `render-gke.py` (`aggregate_ops_per_sec`/`aggregate_mb_per_sec`/etc.).
- [ ] **Step 2: Verify** — run on the existing committed durable results:
  `python3 scripts/render-raw.py results-gke` → `results/raw/durable.md` shows
  78,490 writes/s (p99 23.8 ms), fan-out 119,984 events/s, catch-up 786 MB/s, and the
  2→4→8 saturation rows. No `-`/missing for DS-rust.
- [ ] **Step 3: Commit** — `git add scripts/render-raw.py results/raw/durable.md && git commit -m "feat(bench): DS-rust raw single-node renderer"`.

### Task 6: `scripts/gke-ursula-sweep.sh` — sole-mutator clean preset sweep

**Files:** Create `scripts/gke-ursula-sweep.sh`.

- [ ] **Step 1: Write it** — the earlier sweep was corrupted because TWO runners mutated
  ursula's `--preset` concurrently. This script is the **sole mutator** and strictly
  sequential. For `preset` in `tiny small standard large`:
  set `--preset $preset` in `gke/ursula.yaml` (deterministic `sed`/python edit of the
  args), `kubectl apply`, `kubectl rollout restart deploy/ursula`, `kubectl rollout
  status` + a **3×-consecutive HTTP readiness probe** (reuse gke-run.sh's), then run a
  small `ds-bench multi-stream --streams 50 --duration-secs 8` via the fleet (2 pods),
  merge, and `scripts/logrun.sh ursula preset-$preset multi-stream 2 50 8 <merged.json> "clean sweep"`.
  Print a final table preset→writes/s. `set -euo pipefail`; every kubectl `--context "$CTX" -n ds-bench`.
  ASSERT no other ursula-mutating job is running (e.g. check no `bench-fleet`/sweep Job exists) before starting.
- [ ] **Step 2: Verify** — `bash -n scripts/gke-ursula-sweep.sh`. **Integration gate
  (cluster session):** run it; expect a monotone-ish or peaked preset→throughput curve
  with NO impossible inversions (the 2,684 anomaly must not recur). Gated on a cluster.
- [ ] **Step 3: Commit** — `git add scripts/gke-ursula-sweep.sh && git commit -m "feat(bench): sole-mutator clean ursula preset sweep"`.

### Task 7: `docs/fan-out-outlier-diagnostic.md`

**Files:** Create `docs/fan-out-outlier-diagnostic.md`.

- [ ] **Step 1: Write the procedure** — to confirm/refute ursula single-node fan-out
  p99 = 916 ms (vs published 8.3 ms, 3-node). Steps: (a) re-run ursula fan-out alone at
  fixed `--subscribers`/`--writer-rate`, single client pod, sole server; (b) decompose
  latency: measure write-commit latency (multi-stream p99) vs SSE-delivery delay —
  is 916 ms ≈ commit latency + backlog, or a delivery stall? (c) sweep subscribers
  100→500→1k to see if the tail is load-induced; (d) compare to DS-rust/S2 at the same
  params; (e) decision rule: if reproducible and explained by commit+backlog → keep
  with disclosure; if it vanishes at lower subscriber counts or looks like a harness
  artifact → drop and re-measure. Record findings back into `docs/benchmark-findings.md` §5.
- [ ] **Step 2: Verify** — doc reads coherently; references the live `runlog.tsv` and
  `benchmark-findings.md` §5. (No cluster needed to write the procedure.)
- [ ] **Step 3: Commit** — `git add docs/fan-out-outlier-diagnostic.md && git commit -m "docs: ursula fan-out outlier diagnostic procedure"`.

---

## Follow-on plans (OUT OF SCOPE here)
- **Tier C — sweeps:** payload (100B/1KB/16KB) + subscriber (100→10k) as first-class
  matrix dimensions in the runner + renderer.
- **Tier D — cardinality / millions of streams:** the `ds-bench` `cardinality` workload
  + server-RSS monitoring sidecar + keyspace sharding + N-sweep + recovery timing
  (DS-rust + ursula). Design is in the spec §"Tier D in detail" — needs its own plan.
- **`systems/` restructure:** extract `durable-streams-rust|node`, `ursula`, `s2` into
  `systems/<name>/` adapters + `_CONTRACT.md`, for the publishable pluggable model.

## Self-Review
- **Spec coverage:** Tier A (port + Dockerfile + Option-A Job + run script) ✓; Tier B
  cleanup (raw renderer ✓, clean preset sweep ✓, fan-out diagnostic ✓). Tier C/D +
  systems restructure explicitly deferred ✓.
- **Placeholders:** none — manifests/scripts have concrete content; `REPLACE_RUN_ID`
  is an explicit substitution point documented in Task 4.
- **Path/type consistency:** image `…/ds-bench/micro:dev`; `BIN=/usr/local/bin/durable-streams-server`;
  `DATA=/data`; MinIO prefix `bench-results/micro-$RUN_ID/`; context `gke_vaxine_europe-west1-b_ds-bench`
  — consistent across Dockerfile, Job, and script.
- **Cluster-gated runs** are marked as integration gates (cluster currently down), not
  blockers for the codeable deliverables (port, Dockerfile, manifests, scripts, renderer).
