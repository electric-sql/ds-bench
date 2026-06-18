# Fleet extensions — metrics sidecar + sustained + multi-stream fan-out — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> to implement task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add the three decided capabilities, all on the decoupled/scalable `ds-bench`
fleet: a **server-metrics sidecar** (CPU%/RSS over time), a **`sustained`** workload
(steady load × stream-count sweep), and **multi-stream fan-out** (M streams × S subscribers).

**Architecture:** New `ds-bench` workload modules (`sustained.rs`, `multi_fanout.rs`) —
NEW files, not edits to the forked `multi_stream.rs`/`fanout.rs`. A metrics sidecar in
the server Deployment samples the server process via a shared PID namespace. Run harness
sweeps stream count and collects sidecar samples alongside the merged HDR.

**Tech Stack:** Rust (edition 2024, tokio/reqwest/hdrhistogram), bash, python3, k8s, Cloud Build.

## Global Constraints
- **Forked files stay measurement-identical:** do NOT edit `common.rs`, `backend.rs`,
  `bootstrap.rs`, `fanout.rs`, `multi_stream.rs` measurement logic. New workloads are NEW
  modules (precedent: `catch_up.rs`, `mixed.rs`). Reuse `sse_util.rs` for SSE.
- **Fleet is decoupled + scalable:** these run as the k8s Indexed-Job fleet on `role=client`,
  driving the server over the network — never co-located. The metrics sidecar reads the
  SERVER process; it must not perturb the measurement (cheap polling, nice'd).
- **GKE safety:** every kubectl `--context gke_vaxine_europe-west1-b_ds-bench -n ds-bench`,
  never prod. Images via Cloud Build (amd64), not buildx.
- **Reuse, not duplicate:** the metrics sidecar is shared infra — Tier D (cardinality) will
  reuse it. Design it generic (samples any server pod, any system).
- Branch off `main`; commit per task. Cluster RUNS are integration gates (bring up via `scripts/gke-up.sh`).

## File Structure
```
ds-bench/src/
├── sustained.rs        # NEW: steady-rate, long-duration, stream-count workload
├── multi_fanout.rs     # NEW: M streams × S subscribers fan-out (ours; reuses sse_util)
├── sse_util.rs         # reuse (shared SSE helpers)
└── main.rs             # MODIFY: register `sustained` + `multi-fanout` subcommands
deploy/metrics/
└── poller.sh           # NEW: /proc sampler (CPU+RSS) — the sidecar entrypoint
gke/
├── metrics-sidecar.yaml # NEW: the sidecar container snippet + shareProcessNamespace (doc/patch)
├── durable-streams.yaml # MODIFY: add shareProcessNamespace + the metrics sidecar
scripts/
├── gke-sustained.sh    # NEW: run sustained (stream-count sweep) + collect sidecar + merge
└── render-sustained.py # NEW: throughput/p99 vs stream-count + latency-over-time + RSS-drift
```

---

### Task 1: Server-metrics sidecar (CPU% + RSS over time)

**Files:** Create `deploy/metrics/poller.sh`, `gke/metrics-sidecar.yaml`; modify `gke/durable-streams.yaml`.

**Interfaces:** Produces a time-series `samples.csv` (`ts_ms,rss_bytes,cpu_ticks`) for the
server process, on a shared `emptyDir` at `/metrics`, that the run harness collects.

- [ ] **Step 1: `deploy/metrics/poller.sh`** — samples the server process via the shared
  PID namespace. The server is the non-poller process; find it by binary name.
```bash
#!/usr/bin/env bash
set -euo pipefail
OUT="${METRICS_OUT:-/metrics/samples.csv}"
PROC_NAME="${SERVER_PROC:-durable-streams-server}"
INTERVAL="${METRICS_INTERVAL_S:-1}"
echo "ts_ms,rss_bytes,cpu_ticks" > "$OUT"
while true; do
  pid="$(pgrep -x "$PROC_NAME" | head -1 || true)"
  if [ -n "$pid" ] && [ -r "/proc/$pid/stat" ]; then
    rss_pages=$(awk '{print $24}' "/proc/$pid/stat" 2>/dev/null || echo 0)   # field 24 = rss in pages
    rss=$(( rss_pages * $(getconf PAGE_SIZE) ))
    cpu=$(awk '{s=$0; sub(/^.*\) /,"",s); split(s,f," "); print f[12]+f[13]}' "/proc/$pid/stat" 2>/dev/null || echo 0)
    ts=$(( $(date +%s%N) / 1000000 ))
    echo "${ts},${rss},${cpu}" >> "$OUT"
  fi
  sleep "$INTERVAL"
done
```
  (Uses the post-`)` field parse for CPU, same robustness fix as `micro/lib.sh`. `nice` it in the container command.)
- [ ] **Step 2: `gke/metrics-sidecar.yaml`** — a documented snippet (for reuse across systems): a `metrics` container (`image: …/ds-bench/micro:dev` or a tiny image that has `pgrep`/`bash` — reuse `micro:dev` which has `procps`), `command: ["nice","-n","19","bash","/deploy/metrics/poller.sh"]`, env `SERVER_PROC`, mounting the shared `/metrics` emptyDir; plus the pod-level `shareProcessNamespace: true`. Include the `poller.sh` via a ConfigMap or bake it into the image (prefer ConfigMap so no rebuild: `configMap` volume mounting `poller.sh` at `/deploy/metrics/`).
- [ ] **Step 3: wire into `gke/durable-streams.yaml`** — add `shareProcessNamespace: true` to the pod spec, the `metrics` sidecar container, a `metrics` `emptyDir`, and the `poller.sh` ConfigMap mount. `SERVER_PROC=durable-streams-server`.
- [ ] **Step 4: Verify** — `bash -n deploy/metrics/poller.sh`; `python3 -c "import yaml,sys; list(yaml.safe_load_all(open('gke/durable-streams.yaml')))"`; manually confirm the poller's field-24 RSS + post-`)` CPU parse on a synthetic `/proc/<pid>/stat` line. **Integration gate (cluster):** deploy durable-streams, exec the sidecar, confirm `samples.csv` grows with sane RSS/CPU.
- [ ] **Step 5: Commit** — `git add deploy/metrics gke/metrics-sidecar.yaml gke/durable-streams.yaml && git commit -m "feat(fleet): server-metrics sidecar (CPU/RSS time series via shared PID ns)"`.

---

### Task 2: `sustained` workload (`ds-bench`)

**Files:** Create `ds-bench/src/sustained.rs`; modify `ds-bench/src/main.rs`.

**Interfaces:** Consumes the existing `Backend`/`--api-style` abstraction + the HDR-emit
pattern (read `multi_stream.rs` to match the backend wiring, arg struct, and
`crate::dist::emit_hdr` usage). Produces: a steady-rate, long-duration write load over N
streams, emitting a merged-able HDR + a periodic throughput/latency sample line.

- [ ] **Step 1: Read `ds-bench/src/multi_stream.rs` + `backend.rs`** to match the module
  shape (arg parsing, backend construction, the per-stream writer task, HDR recording,
  `emit_hdr` at the end). `sustained` is `multi_stream` + a **rate limiter** + **long
  duration** + **periodic snapshots**.
- [ ] **Step 2: Write `sustained.rs`** with args: `--target`, `--api-style`, `--streams N`,
  `--rate-per-stream R` (ops/s/stream — the steady offered load; a token-bucket/interval
  ticker per writer, NOT max-throughput), `--duration-secs D` (long, e.g. 300), `--payload-bytes`,
  `--snapshot-secs S` (emit a `{elapsed_s, ops, p50_ms, p99_ms}` line every S secs to stdout
  for the latency-over-time series). Each writer: `tokio::time::interval(1/R)` paced appends,
  record latency into a shared HDR; a snapshot task prints periodic percentiles. At the end,
  `crate::dist::emit_hdr(&hist, &format!("sustained-{}", std::process::id()))` (same pattern
  as multi_stream) and print the final JSON summary (aggregate ops/s, percentiles, streams, duration).
  Use the rate limiter so the load is STEADY (this is the point — measure stability, not peak).
- [ ] **Step 3: register in `main.rs`** — add a `Sustained(SustainedArgs)` subcommand
  dispatching to `sustained::run`, mirroring how `multi-stream`/`catch-up` are registered.
- [ ] **Step 4: Verify** — `cd ds-bench && cargo build --release` passes; a unit test for the
  rate limiter (`#[tokio::test]` asserting ~R ops in ~1s within tolerance); `./target/release/ds-bench sustained --help` lists the args.
- [ ] **Step 5: Commit** — `git add ds-bench/src/sustained.rs ds-bench/src/main.rs && git commit -m "feat(ds-bench): sustained steady-load workload (rate-limited, long-duration, N streams)"`.

---

### Task 3: Multi-stream fan-out (`ds-bench`)

**Files:** Create `ds-bench/src/multi_fanout.rs`; modify `ds-bench/src/main.rs`.

**Interfaces:** Reuses `sse_util.rs` (the SSE subscribe + `extract_send_ns` helpers, same as
`mixed.rs` uses). Produces: M streams, each with a writer + S SSE subscribers, all concurrent;
merged-able fan-out delivery-latency HDR + per-(M,S) summary.

- [ ] **Step 1: Read `ds-bench/src/fanout.rs` + `mixed.rs` + `sse_util.rs`** to match the
  single-stream fan-out measurement (writer embeds send-ns; subscriber records `now − sent`),
  then generalize to M streams. **Do NOT edit `fanout.rs`** (forked) — this is a new module.
- [ ] **Step 2: Write `multi_fanout.rs`** with args: `--target`, `--api-style`, `--streams M`,
  `--subscribers-per-stream S`, `--writer-rate R`, `--duration-secs`, `--payload-bytes`. Spawn,
  per stream: 1 writer (rate R, embeds send-ns via the sse_util payload helper) + S SSE
  subscribers (each records delivery latency into the shared HDR). Use a `Barrier` so all
  subscribers are connected before writers start (the `mixed.rs` deadlock-safe pattern —
  subscribers cross the barrier unconditionally). At the end `emit_hdr(&hist, &format!("multi-fanout-{}", std::process::id()))` + a JSON summary (M, S, events_received, aggregate events/s, percentiles).
- [ ] **Step 3: register in `main.rs`** — `MultiFanout(MultiFanoutArgs)` → `multi_fanout::run`.
- [ ] **Step 4: Verify** — `cargo build --release` passes; `./target/release/ds-bench multi-fanout --help` lists args; if feasible, a small local smoke against a stub is optional (real run is the cluster gate).
- [ ] **Step 5: Commit** — `git add ds-bench/src/multi_fanout.rs ds-bench/src/main.rs && git commit -m "feat(ds-bench): multi-stream fan-out workload (M streams x S subscribers)"`.

---

### Task 4: Rebuild + push the ds-bench image

**Files:** none (uses `scripts/gke-push-images.sh` / the Cloud Build path).

- [ ] **Step 1:** `cargo build --release` in `ds-bench` is green (Tasks 2–3).
- [ ] **Step 2 (integration gate, cluster session):** Cloud-Build + push `ds-bench:dev` (the
  existing build path: `cp dockerfiles/ds-bench.Dockerfile ds-bench/Dockerfile && gcloud builds
  submit ds-bench --tag …/ds-bench:dev && rm ds-bench/Dockerfile`). Verify the new subcommands
  exist: `K run … --image=…/ds-bench:dev -- ds-bench sustained --help`.
- [ ] **Step 3: Commit** — n/a (no file change) unless `gke-push-images.sh` needs a tweak.

---

### Task 5: `scripts/gke-sustained.sh` — run + sweep + collect sidecar

**Files:** Create `scripts/gke-sustained.sh`.

**Interfaces:** `gke-sustained.sh <system> [stream-counts]` → for each stream count in the
sweep (default `10 100 1000 10000`), runs the `sustained` fleet workload, collects the merged
HDR (coordinator-via-object-store, as `gke-run.sh` does) AND the server sidecar `samples.csv`,
into `results/sustained/<RUN_ID>/<N>/`.

- [ ] **Step 1: Write it** — model on `scripts/gke-run.sh` (CTX/`K()`/RUN_ID/object-store
  merge). For each N: substitute `BENCH_CMD="sustained --streams $N --rate-per-stream … --duration-secs 300 --snapshot-secs 5"` into `gke/bench-job.yaml`; apply fleet → coordinator merge; then pull the server pod's `/metrics/samples.csv` (kubectl cp from the running server pod, or have the sidecar upload it to the object store). Also wire a `multi-fanout` invocation path (so this script can run both). Every kubectl via `K`.
- [ ] **Step 2: Verify** — `bash -n scripts/gke-sustained.sh`. **Integration gate:** `scripts/gke-up.sh && scripts/gke-sustained.sh durable 10 100` → `results/sustained/<id>/{10,100}/merged.json` + `samples.csv` present, RSS/latency series non-empty.
- [ ] **Step 3: Commit** — `git add scripts/gke-sustained.sh && git commit -m "feat(fleet): gke-sustained.sh — stream-count sweep + sidecar metrics collection"`.

---

### Task 6: `scripts/render-sustained.py` — the report

**Files:** Create `scripts/render-sustained.py`.

- [ ] **Step 1: Write it** — read `results/sustained/<RUN_ID>/<N>/merged.json` + `samples.csv`
  across the swept N; emit `results/sustained/<RUN_ID>/report.md`: (a) **throughput + p99 vs
  stream count** table; (b) **latency stability over time** (from the snapshot lines / HDR);
  (c) **server RSS drift** (RSS start → end, max, slope from `samples.csv`) vs stream count.
  Disclosures block (single-node, fleet load generator, object tier).
- [ ] **Step 2: Verify** — run on a hand-made sample dir (a `merged.json` + a 3-row `samples.csv`)
  → produces `report.md` with the three sections, no crash.
- [ ] **Step 3: Commit** — `git add scripts/render-sustained.py && git commit -m "feat(fleet): sustained report (throughput/p99 vs streams, latency-over-time, RSS drift)"`.

---

## Follow-on (OUT OF SCOPE here)
- **Tier D cardinality** reuses Task 1's sidecar + the keyspace-sharding pattern → its own plan.
- **Read-size sweep + cpu-scaling-on-fleet** (the throughput studies relocated off `micro/`):
  fold into Tier C's sweep automation — separate plan.
- Apply the metrics sidecar to ursula/S2 deployments (Task 1 is generic — just add the snippet).

## Self-Review
- **Coverage:** sustained workload (T2) ✓, multi-stream fan-out (T3) ✓, metrics sidecar (T1) ✓,
  run+sweep+collect (T5) ✓, report (T6) ✓, image (T4) ✓. Matches the three decisions.
- **Forked-file safety:** `fanout.rs`/`multi_stream.rs` are NOT edited — `multi_fanout.rs`/
  `sustained.rs` are new modules (T2/T3 explicitly read-but-not-edit them). ✓
- **Placeholders:** the poller + interfaces are concrete; Rust boilerplate is delegated to
  "match the existing module" with the novel logic (rate limiter, M×S fan-out, snapshots)
  specified — appropriate for adding modules to an established codebase.
- **Path/name consistency:** subcommands `sustained` / `multi-fanout`; HDR labels
  `sustained-<pid>` / `multi-fanout-<pid>`; results under `results/sustained/`. ✓
- **Cluster-gated** runs (T1 S4, T4 S2, T5 S2) flagged as integration gates; codeable
  deliverables (poller, Rust modules, scripts, renderer) don't need a cluster to build. ✓
