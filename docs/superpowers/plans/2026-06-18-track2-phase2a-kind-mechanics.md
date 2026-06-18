# Track 2 — Phase 2a: distributed harness mechanics on local kind

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the distributed benchmark *mechanics* on a local `kind` cluster (8 GB) at tiny scale: a fleet of `ds-bench` pods runs a workload against one server, each pod emits its raw HDR histogram, and a coordinator merges them into exact fleet-wide percentiles — plus build the `mixed` workload. Correctness, not scale.

**Architecture:** Add an additive, measurement-preserving serialized-HDR emit to the workloads (a one-line call into a new `dist` module), a `ds-bench hdr-merge` coordinator subcommand (exact merge of per-pod histograms), and a `mixed` workload. Drive it with k8s manifests (MinIO + durable-streams + a parallel ds-bench Job + a coordinator Job) on kind, images loaded via `kind load` (no registry). Real scale numbers come later on GKE (Phase 2b, separate plan).

**Tech Stack:** Rust (ds-bench, edition 2024), hdrhistogram 7.5.4 serialization (V2Serializer / Deserializer), kind v0.32, kubectl, Helm, k8s Jobs + PVC, MinIO, Docker.

**Spec:** `docs/superpowers/specs/2026-06-17-scale-out-experiment-design.md` (Phase 2a).

## Global Constraints

- **Local only, 8 GB:** everything runs on a `kind` cluster on the dev machine. **No kube-prometheus-stack** (too heavy). Tiny scale: 1 server, 2–3 client pods, MinIO. Goal is mechanics correctness, not throughput numbers.
- **Never touch a GKE context.** All `kubectl`/`helm` commands target the kind context explicitly (`--context kind-ds-bench`). The current default context is a live GKE cluster — do not use it. After teardown, restore the user's prior context (`kubectl config use-context gke_vaxine_europe-west1_europe-west1-cluster`).
- **Images via `kind load docker-image …  --name ds-bench` — no registry, no login.** Build with Docker, load into kind.
- **Measurement-preserving divergence:** the only edits to the forked `multi_stream.rs`/`fanout.rs` are (1) a single additive call to emit the serialized histogram. No measurement/logic change. The merged-histogram variable already exists at the `summarize(&…)` call site. Update Track 1's "byte-identical/unmodified" wording to "measurement-identical to ursula-bench; only additive output added" (Task 1).
- **Exact merge, not percentile-averaging:** the coordinator merges *raw* histograms (`Histogram::add`) then computes percentiles — never averages per-pod percentiles.
- **durable-streams server is raw-only** (single-engine refactor): no `--http-engine` flag; just run the binary with `--host 0.0.0.0 --port 4438 --data-dir /data --tier s3 …`.
- DRY, YAGNI, TDD, frequent commits. Work on a branch off `main`.

## File Structure

```
ds-rust-bench/
├── ds-bench/src/
│   ├── dist.rs            # NEW (ours): emit_hdr() + the hdr-merge implementation
│   ├── mixed.rs           # NEW (ours): mixed workload
│   ├── main.rs            # MODIFY: mod dist; mod mixed; wire `mixed` + `hdr-merge` subcommands
│   ├── multi_stream.rs    # MODIFY (additive 1 line): emit serialized HDR
│   ├── fanout.rs          # MODIFY (additive 1 line): emit serialized HDR
│   └── catch_up.rs        # MODIFY (additive 1 line): emit serialized HDR
├── k8s/
│   ├── kind-cluster.yaml      # NEW: kind cluster config
│   ├── minio.yaml             # NEW: MinIO Deployment+Service+PVC + bucket-init Job
│   ├── results-pvc.yaml       # NEW: shared PVC for per-pod HDR files
│   ├── durable-streams.yaml   # NEW: DS-rust Deployment+Service
│   ├── bench-job.yaml         # NEW: parallel ds-bench fleet Job (templated)
│   └── coordinator-job.yaml   # NEW: ds-bench hdr-merge Job
├── scripts/
│   └── kind-run.sh            # NEW: create cluster, load images, deploy, run fleet, merge, collect, teardown
├── README.md                  # MODIFY: Track-1 verbatim wording softened (Task 1)
└── docs/superpowers/specs/2026-06-17-single-node-bench-design.md  # MODIFY: same wording (Task 1)
```

---

### Task 1: Additive serialized-HDR emit + soften Track-1 verbatim wording

**Files:** Create `ds-bench/src/dist.rs`; Modify `ds-bench/src/{main.rs,multi_stream.rs,fanout.rs,catch_up.rs}`, `README.md`, `docs/superpowers/specs/2026-06-17-single-node-bench-design.md`.

**Interfaces:**
- Produces: `pub fn dist::emit_hdr(hist: &hdrhistogram::Histogram<u64>, label: &str)` — if env `DS_BENCH_HDR_OUT` is set, serializes `hist` (V2) to `{DS_BENCH_HDR_OUT}/{label}.hdr`; otherwise no-op. Used by every latency workload.

- [ ] **Step 1: Write the failing test**

`ds-bench/tests/hdr_roundtrip.rs`:
```rust
use hdrhistogram::Histogram;

#[test]
fn emit_then_merge_roundtrips_exactly() {
    let dir = std::env::temp_dir().join("ds-bench-hdr-test");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    unsafe { std::env::set_var("DS_BENCH_HDR_OUT", &dir); }

    // two "pods" each record a known set of values
    let mut a = Histogram::<u64>::new_with_bounds(1, 60_000_000, 3).unwrap();
    let mut b = Histogram::<u64>::new_with_bounds(1, 60_000_000, 3).unwrap();
    for v in [10u64, 20, 30] { a.record(v).unwrap(); }
    for v in [40u64, 50, 60] { b.record(v).unwrap(); }
    ds_bench::dist::emit_hdr(&a, "pod-a");
    ds_bench::dist::emit_hdr(&b, "pod-b");

    // merge from the directory == a single histogram over all six values
    let merged = ds_bench::dist::merge_dir(&dir).unwrap();
    let mut expected = Histogram::<u64>::new_with_bounds(1, 60_000_000, 3).unwrap();
    for v in [10u64, 20, 30, 40, 50, 60] { expected.record(v).unwrap(); }
    assert_eq!(merged.len(), expected.len());
    assert_eq!(merged.value_at_quantile(0.5), expected.value_at_quantile(0.5));
    assert_eq!(merged.max(), expected.max());
}
```
Add a `[lib]` + `lib.rs` so the test can reach `ds_bench::dist`:
`ds-bench/src/lib.rs`:
```rust
pub mod dist;
```
`ds-bench/Cargo.toml` add under `[package]`:
```toml
[lib]
name = "ds_bench"
path = "src/lib.rs"
```
(Leave the existing `[[bin]]`; `main.rs` keeps its own `mod` declarations.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ds-bench && cargo test --test hdr_roundtrip`
Expected: FAIL to compile — `ds_bench::dist` / `emit_hdr` / `merge_dir` do not exist.

- [ ] **Step 3: Implement `dist.rs`**

`ds-bench/src/dist.rs`:
```rust
use anyhow::{Context, Result};
use hdrhistogram::serialization::{Deserializer, Serializer, V2Serializer};
use hdrhistogram::Histogram;
use std::path::Path;

/// If DS_BENCH_HDR_OUT is set, serialize `hist` (HdrHistogram V2) to
/// `{DS_BENCH_HDR_OUT}/{label}.hdr`. Additive: callers ignore failures so a
/// missing/unwritable sink never affects the measured run.
pub fn emit_hdr(hist: &Histogram<u64>, label: &str) {
    let Ok(dir) = std::env::var("DS_BENCH_HDR_OUT") else { return };
    let path = Path::new(&dir).join(format!("{label}.hdr"));
    let mut buf = Vec::new();
    if V2Serializer::new().serialize(hist, &mut buf).is_ok() {
        let _ = std::fs::create_dir_all(&dir);
        let _ = std::fs::write(&path, &buf);
    }
}

/// Merge every `*.hdr` file in `dir` into one histogram (exact, lossless).
pub fn merge_dir(dir: &Path) -> Result<Histogram<u64>> {
    let mut merged = Histogram::<u64>::new_with_bounds(1, 60_000_000, 3)
        .context("alloc merged histogram")?;
    merged.auto(true);
    let mut de = Deserializer::new();
    for entry in std::fs::read_dir(dir).context("read hdr dir")? {
        let path = entry?.path();
        if path.extension().and_then(|e| e.to_str()) != Some("hdr") { continue; }
        let bytes = std::fs::read(&path).with_context(|| format!("read {path:?}"))?;
        let h: Histogram<u64> = de
            .deserialize(&mut std::io::Cursor::new(bytes))
            .map_err(|e| anyhow::anyhow!("deserialize {path:?}: {e:?}"))?;
        merged.add(&h).map_err(|e| anyhow::anyhow!("merge {path:?}: {e:?}"))?;
    }
    Ok(merged)
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd ds-bench && cargo test --test hdr_roundtrip`
Expected: PASS (merged p50/len/max equal the single-histogram expectation).

- [ ] **Step 5: Wire the additive emit into the three workloads**

In `multi_stream.rs`: find the `summarize(&h)` call (≈ line 177). Immediately after it, add:
```rust
    crate::dist::emit_hdr(&h, &format!("multi-stream-{}", std::process::id()));
```
In `fanout.rs`: after the `summarize(&hist)` call (≈ line 154), add (lock if needed — match the variable type at that line; if `hist` is the owned histogram there, pass `&hist`):
```rust
    crate::dist::emit_hdr(&hist, &format!("fanout-{}", std::process::id()));
```
In `catch_up.rs`: after its `summarize(...)` of the merged histogram, add:
```rust
    crate::dist::emit_hdr(&h, &format!("catch-up-{}", std::process::id()));
```
Add `mod dist;` to `main.rs`. (Each workload now ALSO writes a `.hdr` file when `DS_BENCH_HDR_OUT` is set; default behavior — JSON to stdout — is unchanged.)

- [ ] **Step 6: Soften the Track-1 verbatim wording**

In `README.md` and `docs/superpowers/specs/2026-06-17-single-node-bench-design.md`, replace the "byte-identical / verbatim fork / unmodified" claims with this honest framing (keep the spirit, state the exact change):
> `ds-bench` is **derived from ursula-bench** (Apache-2.0). The per-client **measurement
> logic is ursula's, unchanged**; our only edits to the upstream workloads are **additive
> output** — each workload also serializes its HDR histogram to a file (for exact
> cross-fleet merge in Track 2) when `DS_BENCH_HDR_OUT` is set. Verifiable as a small
> additive diff that touches no measurement code. `catch_up.rs` and `mixed.rs` are our own.

- [ ] **Step 7: Build + commit**

Run: `cd ds-bench && cargo build --release && cargo test --test hdr_roundtrip`
Expected: builds; test passes.
```bash
git add ds-bench README.md docs/superpowers/specs/2026-06-17-single-node-bench-design.md
git commit -m "feat(ds-bench): additive serialized-HDR emit + merge_dir; soften verbatim wording"
```

---

### Task 2: `ds-bench hdr-merge` coordinator subcommand

**Files:** Modify `ds-bench/src/dist.rs` (add the command impl + result struct), `ds-bench/src/main.rs` (CLI wiring).

**Interfaces:**
- Consumes: `dist::merge_dir` (Task 1).
- Produces: subcommand `ds-bench hdr-merge --hdr-dir <dir> [--results-dir <dir>]` → prints JSON `{ "merged_count": u64, "p50_ms": f64, "p90_ms": f64, "p99_ms": f64, "p999_ms": f64, "max_ms": f64, "aggregate_ops_per_sec": f64 }`. `aggregate_ops_per_sec` = sum of `aggregate_ops_per_sec` across any per-pod `*.json` in `--results-dir` (0.0 if none provided).

- [ ] **Step 1: Write the failing test**

Append to `ds-bench/tests/hdr_roundtrip.rs`:
```rust
#[test]
fn hdr_merge_summary_matches_merged_histogram() {
    let dir = std::env::temp_dir().join("ds-bench-hdr-merge-test");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let mut a = Histogram::<u64>::new_with_bounds(1, 60_000_000, 3).unwrap();
    for v in 1u64..=1000 { a.record(v * 1000).unwrap(); } // values in µs
    {
        use hdrhistogram::serialization::{Serializer, V2Serializer};
        let mut buf = Vec::new();
        V2Serializer::new().serialize(&a, &mut buf).unwrap();
        std::fs::write(dir.join("only.hdr"), &buf).unwrap();
    }
    let summary = ds_bench::dist::merge_summary(&dir, None).unwrap();
    assert_eq!(summary.merged_count, 1000);
    // p50 of 1..=1000 (×1000 µs) ≈ 500 ms, within HDR precision
    assert!((summary.p50_ms - 500.0).abs() < 5.0, "p50_ms={}", summary.p50_ms);
}
```
Add `pub mod dist;` already exists in lib.rs; ensure `MergeSummary` + `merge_summary` are `pub`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ds-bench && cargo test --test hdr_roundtrip hdr_merge_summary_matches_merged_histogram`
Expected: FAIL — `merge_summary` / `MergeSummary` not defined.

- [ ] **Step 3: Implement `merge_summary` + the CLI in `dist.rs`**

Add to `dist.rs`:
```rust
use serde::Serialize;

#[derive(Serialize)]
pub struct MergeSummary {
    pub merged_count: u64,
    pub p50_ms: f64,
    pub p90_ms: f64,
    pub p99_ms: f64,
    pub p999_ms: f64,
    pub max_ms: f64,
    pub aggregate_ops_per_sec: f64,
}

fn sum_ops(results_dir: Option<&Path>) -> f64 {
    let Some(dir) = results_dir else { return 0.0 };
    let mut total = 0.0;
    if let Ok(rd) = std::fs::read_dir(dir) {
        for entry in rd.flatten() {
            let p = entry.path();
            if p.extension().and_then(|e| e.to_str()) != Some("json") { continue; }
            if let Ok(txt) = std::fs::read_to_string(&p) {
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(&txt) {
                    total += v.get("aggregate_ops_per_sec").and_then(|x| x.as_f64()).unwrap_or(0.0);
                }
            }
        }
    }
    total
}

pub fn merge_summary(hdr_dir: &Path, results_dir: Option<&Path>) -> Result<MergeSummary> {
    let h = merge_dir(hdr_dir)?;
    let ms = |v: u64| (v as f64) / 1000.0;
    Ok(MergeSummary {
        merged_count: h.len(),
        p50_ms: ms(h.value_at_quantile(0.5)),
        p90_ms: ms(h.value_at_quantile(0.9)),
        p99_ms: ms(h.value_at_quantile(0.99)),
        p999_ms: ms(h.value_at_quantile(0.999)),
        max_ms: ms(h.max()),
        aggregate_ops_per_sec: sum_ops(results_dir),
    })
}

#[derive(clap::Args, Debug, Clone)]
pub struct HdrMergeArgs {
    /// Directory containing per-pod *.hdr files.
    #[arg(long)]
    pub hdr_dir: String,
    /// Optional directory of per-pod *.json results (sums aggregate_ops_per_sec).
    #[arg(long)]
    pub results_dir: Option<String>,
}

pub fn run_merge(args: HdrMergeArgs) -> Result<String> {
    let results = args.results_dir.as_ref().map(Path::new);
    let summary = merge_summary(Path::new(&args.hdr_dir), results)?;
    Ok(serde_json::to_string_pretty(&summary)?)
}
```

- [ ] **Step 4: Wire the subcommand in `main.rs`**

Add `HdrMerge(dist::HdrMergeArgs)` to the `Cmd` enum (with doc `/// Merge per-pod HDR histograms into exact fleet-wide percentiles.`), and the dispatch arm:
```rust
        Cmd::HdrMerge(a) => dist::run_merge(a)?,
```
(Note: `run_merge` already returns the JSON string; the other arms return strings too — match the existing pattern.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd ds-bench && cargo test --test hdr_roundtrip && cargo build --release`
Expected: tests pass; `./target/release/ds-bench hdr-merge --help` shows `--hdr-dir`.

- [ ] **Step 6: Commit**

```bash
git add ds-bench
git commit -m "feat(ds-bench): hdr-merge subcommand (exact fleet-wide percentiles)"
```

---

### Task 3: `mixed` workload

**Files:** Create `ds-bench/src/mixed.rs`; Modify `ds-bench/src/main.rs`.

**Interfaces:**
- Consumes: `backend::{Backend, ApiStyle, Producer}`, `common::{build_client, new_histogram, record, summarize, merge, fill_payload, Counts, LatencySummary}`, `dist::emit_hdr`.
- Produces: subcommand `mixed` with `MixedArgs`; `pub async fn run(args: MixedArgs) -> anyhow::Result<MixedResult>`.

- [ ] **Step 1: Define the workload (read the existing modules first)**

Read `ds-bench/src/multi_stream.rs`, `fanout.rs`, and `catch_up.rs` to reuse their exact patterns (`Backend` method signatures, `Producer{id,epoch,seq}`, `Counts`, `Semaphore`/`Barrier`, error classification). Then create `ds-bench/src/mixed.rs`:

`MixedArgs` (clap `Args`): `--target`, `--api-style` (default Ursula), `--bucket` (default `bench-mixed`), `--basin`, `--streams` (default 50), `--writers-per-stream` (default 1), `--readers` (default 50), `--subscribers` (default 50), `--writer-rate` (default 50), `--duration-secs` (default 30), `--payload-bytes` (default 256), `--setup-concurrency` (default 32), `--request-timeout-secs` (default 30).

Control flow:
1. `ensure_namespace()`; create `streams` streams named `s{idx:06}` (content-type `application/octet-stream`), pre-loading each with a small backfill (e.g. 200 events) so catch-up readers have data.
2. Spawn, all sharing a deadline = now + `duration_secs`:
   - `writers-per-stream * streams` writer tasks: append at `writer_rate` to their stream (Producer epoch 0, incrementing seq for ursula/durable; None for s2). Record append latency into a shared `Mutex<Histogram>` `write_hist`.
   - `subscribers` SSE subscriber tasks across the streams (round-robin), recording end-to-end fan-out latency into `Mutex<Histogram>` `fanout_hist` (reuse fanout.rs's `extract_send_ns` approach — copy the helper into mixed.rs; the writer payload must embed the ns timestamp like fanout's `build_payload`).
   - `readers` catch-up reader tasks that repeatedly catch-up read a random stream from offset 0 until `Stream-Up-To-Date` (reuse the `catch_up_read_all` DS-protocol loop from catch_up.rs — make it `pub(crate)` if needed, or copy it), recording read latency into `Mutex<Histogram>` `read_hist`.
3. After the deadline, `summarize` each of the three histograms; call `dist::emit_hdr` for each with labels `mixed-write-{pid}`, `mixed-fanout-{pid}`, `mixed-read-{pid}`.

`MixedResult` (serde Serialize): `scenario: "mixed"`, `api_style`, `target`, `bucket`, `streams`, `writers_per_stream`, `readers`, `subscribers`, `writer_rate`, `duration_secs`, `payload_bytes`, `elapsed_secs`, `write_counts: Counts`, `events_received: u64`, `read_counts: Counts`, `aggregate_ops_per_sec: f64` (writes ok / elapsed), `write_latency_ms`, `fan_out_latency_ms`, `read_latency_ms` (each a `LatencySummary`).

S2 note: `mixed` requires catch-up reads, which S2 can't do comparably — so `run()` must `anyhow::bail!("mixed workload is not supported for S2 Lite (no comparable catch-up read)")` when `api_style == ApiStyle::S2` (mirror the guard in catch_up.rs).

- [ ] **Step 2: Wire CLI + a build check (the test is the build + a local smoke in Task 8)**

Add `mod mixed;` and `Mixed(mixed::MixedArgs)` to `Cmd` + dispatch `Cmd::Mixed(a) => serde_json::to_string_pretty(&mixed::run(a).await?)?`.
Run: `cd ds-bench && cargo build --release`
Expected: compiles; `./target/release/ds-bench --help` lists `mixed`; `ds-bench mixed --api-style s2 --target http://x` exits non-zero with the S2 guard message.

- [ ] **Step 3: Verify mixed runs against a local durable-streams server**

Build/run a local durable-streams-server (hyper or default, `--tier off`) as in `scripts/smoke-durable.sh`, then:
```bash
DS_BENCH_HDR_OUT=$(mktemp -d) ./ds-bench/target/release/ds-bench mixed \
  --target http://127.0.0.1:4470 --api-style durable \
  --streams 4 --readers 4 --subscribers 4 --duration-secs 5 1>/tmp/mixed.json 2>/tmp/mixed.err
jq '{w:.write_counts.ok, ev:.events_received, r:.read_counts.ok}' /tmp/mixed.json
ls "$DS_BENCH_HDR_OUT"   # expect mixed-write-*.hdr, mixed-fanout-*.hdr, mixed-read-*.hdr
```
Expected: `write_counts.ok > 0`, `events_received > 0`, `read_counts.ok > 0`, and three `.hdr` files written.

- [ ] **Step 4: Commit**

```bash
git add ds-bench
git commit -m "feat(ds-bench): mixed workload (writers + catch-up readers + SSE subscribers)"
```

---

### Task 4: kind cluster config + ds-bench image

**Files:** Create `k8s/kind-cluster.yaml`.

- [ ] **Step 1: Write `k8s/kind-cluster.yaml`**

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ds-bench
nodes:
  - role: control-plane
```
(Single node — 8 GB can't host more; the fleet runs as multiple pods on the one node.)

- [ ] **Step 2: Create the cluster + build & load the ds-bench image (the test)**

```bash
kind create cluster --config k8s/kind-cluster.yaml
docker compose build bench            # produces ds-bench/ds-bench:dev with the new binary
kind load docker-image ds-bench/ds-bench:dev --name ds-bench
kubectl --context kind-ds-bench get nodes
```
Expected: cluster `ds-bench` is up; `kind load` reports the image loaded; node is Ready.

- [ ] **Step 3: Commit**

```bash
git add k8s/kind-cluster.yaml
git commit -m "feat(k8s): kind cluster config"
```

---

### Task 5: MinIO + results PVC on kind

**Files:** Create `k8s/minio.yaml`, `k8s/results-pvc.yaml`.

- [ ] **Step 1: Write `k8s/minio.yaml`** (Deployment + Service + a bucket-init Job)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: minio, labels: { app: minio } }
spec:
  replicas: 1
  selector: { matchLabels: { app: minio } }
  template:
    metadata: { labels: { app: minio } }
    spec:
      containers:
        - name: minio
          image: minio/minio:latest
          args: ["server", "/data", "--console-address", ":9001"]
          env:
            - { name: MINIO_ROOT_USER, value: minioadmin }
            - { name: MINIO_ROOT_PASSWORD, value: minioadmin }
          ports: [{ containerPort: 9000 }, { containerPort: 9001 }]
          resources: { requests: { memory: "256Mi", cpu: "100m" }, limits: { memory: "512Mi" } }
---
apiVersion: v1
kind: Service
metadata: { name: minio }
spec:
  selector: { app: minio }
  ports: [{ name: s3, port: 9000, targetPort: 9000 }]
---
apiVersion: batch/v1
kind: Job
metadata: { name: minio-init }
spec:
  backoffLimit: 10
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: mc
          image: minio/mc:latest
          command: ["/bin/sh","-c"]
          args:
            - >
              until mc alias set local http://minio:9000 minioadmin minioadmin; do sleep 2; done &&
              mc mb -p local/durable-streams && echo buckets-ready
```

- [ ] **Step 2: Write `k8s/results-pvc.yaml`**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: bench-results }
spec:
  accessModes: ["ReadWriteOnce"]
  resources: { requests: { storage: 1Gi } }
```
(kind's default StorageClass `standard` is `ReadWriteOnce`; the fleet Job and the coordinator Job run on the single node, so RWO is fine.)

- [ ] **Step 3: Apply + verify (the test)**

```bash
kubectl --context kind-ds-bench apply -f k8s/minio.yaml -f k8s/results-pvc.yaml
kubectl --context kind-ds-bench wait --for=condition=available deploy/minio --timeout=120s
kubectl --context kind-ds-bench wait --for=condition=complete job/minio-init --timeout=120s
kubectl --context kind-ds-bench logs job/minio-init | tail -1   # expect: buckets-ready
kubectl --context kind-ds-bench get pvc bench-results           # expect: Bound
```
Expected: MinIO available, `minio-init` prints `buckets-ready`, PVC `Bound`.

- [ ] **Step 4: Commit**

```bash
git add k8s/minio.yaml k8s/results-pvc.yaml
git commit -m "feat(k8s): MinIO + results PVC"
```

---

### Task 6: durable-streams server on kind

**Files:** Create `k8s/durable-streams.yaml`.

- [ ] **Step 1: Build + load the DS-rust image into kind**

```bash
docker build -f dockerfiles/durable-streams.Dockerfile -t ds-bench/durable-streams:dev ../durable-streams
kind load docker-image ds-bench/durable-streams:dev --name ds-bench
```
Expected: image built + loaded.

- [ ] **Step 2: Write `k8s/durable-streams.yaml`** (raw-only binary; offload to in-cluster MinIO)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: durable-streams, labels: { app: durable-streams } }
spec:
  replicas: 1
  selector: { matchLabels: { app: durable-streams } }
  template:
    metadata: { labels: { app: durable-streams } }
    spec:
      containers:
        - name: durable-streams
          image: ds-bench/durable-streams:dev
          imagePullPolicy: Never        # use the kind-loaded image, never pull
          args:
            - "--host"; ["0.0.0.0"]      # NOTE: render as separate YAML list items (see below)
          env:
            - { name: DS_S3_ACCESS_KEY_ID, value: minioadmin }
            - { name: DS_S3_SECRET_ACCESS_KEY, value: minioadmin }
          ports: [{ containerPort: 4438 }]
          resources: { requests: { memory: "256Mi", cpu: "250m" }, limits: { memory: "1Gi" } }
---
apiVersion: v1
kind: Service
metadata: { name: durable-streams }
spec:
  selector: { app: durable-streams }
  ports: [{ port: 4438, targetPort: 4438 }]
```
Write `args` as separate tokens (the server's hand-rolled parser rejects `--flag=value`):
```yaml
          args:
            - "--host"
            - "0.0.0.0"
            - "--port"
            - "4438"
            - "--data-dir"
            - "/data"
            - "--tier"
            - "s3"
            - "--tier-endpoint"
            - "http://minio:9000"
            - "--tier-region"
            - "us-east-1"
            - "--tier-bucket"
            - "durable-streams"
            - "--tier-allow-http"
```
(Replace the placeholder `--host` line above with this full block. No `--http-engine` — the server is raw-only.)

- [ ] **Step 3: Apply + verify the server serves (the test)**

```bash
kubectl --context kind-ds-bench apply -f k8s/durable-streams.yaml
kubectl --context kind-ds-bench wait --for=condition=available deploy/durable-streams --timeout=120s
# in-cluster reachability: a one-shot curl pod
kubectl --context kind-ds-bench run curlcheck --rm -i --restart=Never --image=curlimages/curl:latest -- \
  sh -c 'curl -sS -X PUT http://durable-streams:4438/v1/stream/smoke -H "content-type: application/octet-stream" -o /dev/null -w "%{http_code}\n"'
```
Expected: the curl pod prints `201` (or `200`) — the server is up and serving on the cluster network.

- [ ] **Step 4: Commit**

```bash
git add k8s/durable-streams.yaml
git commit -m "feat(k8s): durable-streams server (raw-only, MinIO offload)"
```

---

### Task 7: ds-bench fleet Job + coordinator Job

**Files:** Create `k8s/bench-job.yaml`, `k8s/coordinator-job.yaml`.

**Interfaces:**
- Consumes: the `ds-bench/ds-bench:dev` image, the `bench-results` PVC, the `durable-streams` Service.
- Produces: a parallel Job whose pods each write `{workload}-{pid}.hdr` + a per-pod `.json` to the PVC under `/results`; a coordinator Job that runs `ds-bench hdr-merge` over the PVC.

- [ ] **Step 1: Write `k8s/bench-job.yaml`** (a 2-pod fleet running `multi-stream`; env-substituted by the run script)

```yaml
apiVersion: batch/v1
kind: Job
metadata: { name: bench-fleet }
spec:
  completions: 2
  parallelism: 2
  completionMode: Indexed        # gives each pod JOB_COMPLETION_INDEX
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: ds-bench
          image: ds-bench/ds-bench:dev
          imagePullPolicy: Never
          env:
            - { name: DS_BENCH_HDR_OUT, value: /results }
          command: ["/bin/sh","-c"]
          # write per-pod JSON to /results/<index>.json; HDR auto-named by the binary
          args:
            - >
              ds-bench multi-stream --target http://durable-streams:4438 --api-style durable
              --streams 20 --duration-secs 15 --payload-bytes 256
              > /results/ms-${JOB_COMPLETION_INDEX}.json
          volumeMounts: [{ name: results, mountPath: /results }]
          resources: { requests: { memory: "128Mi", cpu: "250m" }, limits: { memory: "512Mi" } }
      volumes:
        - name: results
          persistentVolumeClaim: { claimName: bench-results }
```

- [ ] **Step 2: Write `k8s/coordinator-job.yaml`**

```yaml
apiVersion: batch/v1
kind: Job
metadata: { name: bench-coordinator }
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: coordinator
          image: ds-bench/ds-bench:dev
          imagePullPolicy: Never
          command: ["/bin/sh","-c"]
          args:
            - "ds-bench hdr-merge --hdr-dir /results --results-dir /results > /results/merged.json && cat /results/merged.json"
          volumeMounts: [{ name: results, mountPath: /results }]
      volumes:
        - name: results
          persistentVolumeClaim: { claimName: bench-results }
```

- [ ] **Step 3: Run the fleet + coordinator + verify the merge (the test)**

```bash
kubectl --context kind-ds-bench apply -f k8s/bench-job.yaml
kubectl --context kind-ds-bench wait --for=condition=complete job/bench-fleet --timeout=180s
kubectl --context kind-ds-bench apply -f k8s/coordinator-job.yaml
kubectl --context kind-ds-bench wait --for=condition=complete job/bench-coordinator --timeout=120s
kubectl --context kind-ds-bench logs job/bench-coordinator
```
Expected: coordinator logs a JSON `merged.json` with `merged_count` ≈ the sum of both pods' append counts, real `p50_ms/p99_ms`, and `aggregate_ops_per_sec` ≈ sum of the two pods' rates. (Two pods' histograms were merged into one exact set of percentiles.)

- [ ] **Step 4: Commit**

```bash
git add k8s/bench-job.yaml k8s/coordinator-job.yaml
git commit -m "feat(k8s): ds-bench fleet Job + HDR-merge coordinator Job"
```

---

### Task 8: `kind-run.sh` end-to-end harness + all-workloads validation

**Files:** Create `scripts/kind-run.sh`.

- [ ] **Step 1: Write `scripts/kind-run.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
# End-to-end Phase-2a mechanics run on a local kind cluster. Tiny scale; mechanics only.
# Usage: scripts/kind-run.sh [workload]   workload ∈ multi-stream|fan-out|catch-up|mixed (default multi-stream)
CTX=kind-ds-bench
WL="${1:-multi-stream}"
PRIOR_CTX="$(kubectl config current-context 2>/dev/null || true)"
cleanup() { kind delete cluster --name ds-bench >/dev/null 2>&1 || true; [ -n "$PRIOR_CTX" ] && kubectl config use-context "$PRIOR_CTX" >/dev/null 2>&1 || true; }
trap cleanup EXIT

kind create cluster --config k8s/kind-cluster.yaml
docker compose build bench
docker build -f dockerfiles/durable-streams.Dockerfile -t ds-bench/durable-streams:dev ../durable-streams
kind load docker-image ds-bench/ds-bench:dev --name ds-bench
kind load docker-image ds-bench/durable-streams:dev --name ds-bench

kubectl --context $CTX apply -f k8s/minio.yaml -f k8s/results-pvc.yaml
kubectl --context $CTX wait --for=condition=complete job/minio-init --timeout=180s
kubectl --context $CTX apply -f k8s/durable-streams.yaml
kubectl --context $CTX wait --for=condition=available deploy/durable-streams --timeout=180s

# substitute the workload into the fleet Job command, then run it
sed "s/multi-stream --target/${WL} --target/" k8s/bench-job.yaml | kubectl --context $CTX apply -f -
kubectl --context $CTX wait --for=condition=complete job/bench-fleet --timeout=300s
kubectl --context $CTX apply -f k8s/coordinator-job.yaml
kubectl --context $CTX wait --for=condition=complete job/bench-coordinator --timeout=120s
echo "=== merged result ($WL) ==="; kubectl --context $CTX logs job/bench-coordinator
```
(For `fan-out`/`mixed` the fleet Job command's flags differ; the script's `sed` swaps the subcommand, and the workload-specific flags in `bench-job.yaml` are tolerated/ignored or adjusted — keep `--target … --api-style durable --duration-secs 15` common. If a workload needs distinct flags, add a per-workload args block in a follow-up; for Phase-2a mechanics the defaults suffice.)

- [ ] **Step 2: Run the harness for multi-stream (the test)**

```bash
chmod +x scripts/kind-run.sh
scripts/kind-run.sh multi-stream
```
Expected: ends by printing a merged JSON with non-zero `merged_count`, `p50_ms`, `p99_ms`, `aggregate_ops_per_sec`; cluster torn down; your GKE context restored (`kubectl config current-context` → the prior GKE context).

- [ ] **Step 3: Run the harness for fan-out and catch-up**

```bash
scripts/kind-run.sh fan-out
scripts/kind-run.sh catch-up
```
Expected: each prints a merged JSON with non-zero percentiles. (mixed needs distinct flags — validate it via the Task-3 local smoke; wiring mixed into the fleet Job's flag set is a Phase-2b refinement.)

- [ ] **Step 4: Commit**

```bash
git add scripts/kind-run.sh
git commit -m "feat: kind-run.sh end-to-end Phase-2a mechanics harness"
```

---

## Self-Review

**Spec coverage (Phase 2a success criteria):**
- Manifests apply on kind → Tasks 4-7. ✓
- MinIO + one server + small ds-bench Job fleet run workloads at tiny scale → Tasks 5-8. ✓
- Per-pod serialized HDR merges into unified percentiles → Tasks 1-2 (code + test), 7-8 (in-cluster). ✓
- MinIO offload (DS `--tier s3`) → Task 6. ✓
- `mixed` workload built → Task 3. ✓
- No kube-prometheus-stack; merged-HDR JSON is source of truth → coordinator (Tasks 2,7). ✓
- Never touch GKE; restore context → Global Constraints + Task 8 `kind-run.sh` trap. ✓
- Soften Track-1 verbatim wording (the divergence ripple) → Task 1 Step 6. ✓

**Deferred to Phase 2b (noted, not gaps):** DS-node + ursula(1/3/5) + S2 manifests; per-pod stream **sharding** for multi-stream (Phase-2a accepts fleet collisions for mechanics); Prometheus/Grafana; real saturation scale; Artifact Registry. The `mixed` fleet-flag wiring is a 2b refinement (mixed is validated locally in Task 3).

**Placeholder scan:** the `k8s/durable-streams.yaml` Step 1 shows a placeholder `--host` line explicitly replaced by the full args block in the same step — not a left-in placeholder. No TODO/TBD.

**Type consistency:** `dist::emit_hdr(&Histogram<u64>, &str)`, `dist::merge_dir(&Path)->Result<Histogram>`, `dist::merge_summary(&Path, Option<&Path>)->Result<MergeSummary>`, `MergeSummary` fields (`merged_count,p50_ms,p90_ms,p99_ms,p999_ms,max_ms,aggregate_ops_per_sec`) — defined Task 1-2, consumed by the coordinator Job (Task 7) via `ds-bench hdr-merge --hdr-dir --results-dir`. CLI names (`hdr-merge`, `mixed`) consistent across main.rs wiring, the Job YAMLs, and kind-run.sh.

**Note:** the `[lib]` addition (Task 1) makes `ds_bench` a library + binary; `main.rs` keeps its own `mod` declarations for the binary, while `lib.rs` exposes `dist` for tests. Confirm both compile (the binary's `mod dist;` and the lib's `pub mod dist;` refer to the same file — Rust allows a module in both crates of a package).
