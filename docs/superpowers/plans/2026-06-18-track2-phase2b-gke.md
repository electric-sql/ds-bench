# Track 2 — Phase 2b: scale-out experiment on dedicated GKE

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the distributed scale-out benchmark on a dedicated GKE cluster to produce REAL (publishable-candidate) numbers — reusing the Phase-2a harness (ds-bench fleet → coordinator → exact HDR merge), adapted from a single-node kind cluster to a multi-node GKE cluster.

**Architecture:** A dedicated zonal GKE cluster with two `n2d` node pools — a NVMe-backed `role=server` pool (one server-under-test + in-cluster MinIO) and a scalable `role=client` pool (the ds-bench fleet). Images come from Artifact Registry. Because the client fleet now spans MULTIPLE nodes, the Phase-2a ReadWriteOnce PVC for results is replaced by per-pod upload to in-cluster MinIO + a coordinator that pulls and merges. Two milestones: 2b.1 proves the GKE plumbing end-to-end with one server; 2b.2 runs the full system × workload × sweep matrix and renders the report.

**Tech Stack:** GKE (zonal, `n2d`, Local SSD), gcloud + Artifact Registry, kubectl + Helm, k8s Jobs/Deployments + nodeSelectors, MinIO (in-cluster on NVMe) + `mc`, Rust (ds-bench), Python (report render).

**Spec:** `docs/superpowers/specs/2026-06-17-scale-out-experiment-design.md` (Phase 2b). **Builds on:** Phase 2a (merged to main) — `ds-bench` (HDR emit/`merge_dir`/`hdr-merge --label-prefix`, 4 workloads), `k8s/*.yaml`, `scripts/kind-run.sh`.

## Global Constraints

- **Dedicated cluster only; never prod.** Cluster `ds-bench`, **zonal `europe-west1-b`** (single zone → no cross-zone egress). All kubectl uses `--context <ds-bench gke context>` and namespace `ds-bench`. NEVER touch `vaxine` or any other existing context. Tear the cluster down after runs.
- **Node pools (both AMD `n2d`, x86/amd64 — no image-arch change):**
  - `role=server`: `n2d-standard-8`, `--ephemeral-storage-local-ssd count=1` (375 GB NVMe → pod ephemeral/`emptyDir` on NVMe for fast fsync). 1 node.
  - `role=client`: `n2d-standard-16`, label `role=client`, scalable (start 2 nodes).
- **Object store = in-cluster MinIO on the NVMe `role=server` node — NOT GCS.** Same MinIO + identical config for ALL systems (fairness). Disclose in the report: "object tier = in-cluster MinIO on local NVMe (near-best-case, not cloud-S3 latency)." (GCS-via-S3-compat was considered and explicitly rejected for now.)
- **Images via Artifact Registry** `europe-west1-docker.pkg.dev/<PROJECT>/ds-bench/<name>:<tag>`, **amd64**. Replace Phase-2a `imagePullPolicy: Never` with registry refs + `imagePullPolicy: Always`. ursula via its **Helm chart**; S2 Lite from public `ghcr.io/s2-streamstore/s2` (anonymous pull — confirmed works).
- **Cross-node results aggregation (the central adaptation):** the multi-node client fleet CANNOT share a ReadWriteOnce PVC. Each fleet pod writes its `.hdr`/`.json` locally (`DS_BENCH_HDR_OUT`) then uploads to in-cluster MinIO under `s3://bench-results/<RUN_ID>/`; the coordinator downloads all and runs `ds-bench hdr-merge`. (Alternative noted, not used: a ReadWriteMany Filestore PVC — ~$0.20/GB/hr, 1 TB min = expensive overkill.)
- **Matched durability + fairness (carry from spec):** ursula `[raft.wal] backend=disk`; durable-streams fsync; all offload to the same MinIO; one server-under-test per measured run; identical ds-bench params across systems; group-commit-symmetry disclosure; S2 durability-substrate disclosure.
- **Multi-node honesty split (critical):** ursula at 3/5 nodes pays cross-node Raft replication that single-node DS-rust does not. Report two SEPARATE stories — (a) single-node head-to-head, (b) ursula's own scale-out curve — until DS-rust has multi-node (Phase 3). Never headline a single-node DS number vs a 3-node ursula number.
- **Systems × topology (first GKE run):** DS-rust ×{1}, DS-node ×{1}, ursula ×{1,3,5}, S2 Lite ×{1}. **S2 in write + fan-out only** (excluded from catch-up AND mixed — its paginated/JSON-enveloped read isn't comparable; ds-bench already bails for S2 on both).
- DRY, YAGNI, TDD-where-it-fits, frequent commits. Work on a branch off `main`.

## File Structure

```
ds-rust-bench/
├── dockerfiles/
│   ├── ds-bench.Dockerfile          # MODIFY: also install `mc` (MinIO client) for HDR upload/download
│   └── ds-node.Dockerfile           # NEW (2b.2): Node/TS durable-streams server image
├── ds-bench/src/
│   ├── dist.rs                      # MODIFY: per-workload headline metric in MergeSummary (fix ops/s=0 for fan-out/catch-up)
│   ├── sse_util.rs                  # NEW (2b.2): shared SSE/payload helpers lifted from fanout/mixed (DRY)
│   └── mixed.rs / fanout-usage      # mixed.rs uses sse_util (fanout.rs stays verbatim — see Task notes)
├── gke/
│   ├── minio.yaml                   # NEW: MinIO on role=server, NVMe-backed, real resources
│   ├── durable-streams.yaml         # NEW: DS-rust Deployment (registry image, role=server, NVMe data-dir)
│   ├── ds-node.yaml                 # NEW (2b.2)
│   ├── s2lite.yaml                  # NEW (2b.2)
│   ├── ursula-values.yaml           # NEW (2b.2): Helm values (disk WAL, MinIO cold tier, replicas)
│   ├── bench-job.yaml               # NEW: fleet Job, role=client, multi-node, uploads HDR to MinIO
│   └── coordinator-job.yaml         # NEW: pulls run HDRs from MinIO, runs hdr-merge
├── scripts/
│   ├── gke-up.sh                    # NEW: idempotent cluster + node pools + AR + namespace
│   ├── gke-down.sh                  # NEW: delete the cluster (stop billing)
│   ├── gke-push-images.sh           # NEW: build+push amd64 images to Artifact Registry
│   ├── gke-run.sh                   # NEW: run one workload (system) end-to-end → merged result
│   ├── gke-matrix.sh                # NEW (2b.2): full systems × workloads × sweeps matrix
│   └── render-results.py            # MODIFY (2b.2): saturation/scale-out/subscriber curves
└── docs/superpowers/plans/2026-06-18-track2-phase2b-gke.md   # this plan
```

(Phase-2b k8s manifests live under `gke/` to keep them distinct from the Phase-2a `k8s/` kind manifests.)

---

## Phase 2b.1 — GKE plumbing gate (one server, prove cross-node merge)

### Task 1: Cluster + node pools + Artifact Registry + namespace (`gke-up.sh` / `gke-down.sh`)

**Files:** Create `scripts/gke-up.sh`, `scripts/gke-down.sh`.

**Interfaces:** Produces a running cluster `ds-bench` (zonal `europe-west1-b`), node pools `role=server` (NVMe) + `role=client`, an Artifact Registry docker repo `ds-bench`, namespace `ds-bench`, and the kubectl context wired.

- [ ] **Step 1: Write `scripts/gke-up.sh`** (idempotent; `set -euo pipefail`; takes `PROJECT` from `gcloud config` or `$1`)

```bash
#!/usr/bin/env bash
set -euo pipefail
PROJECT="${1:-$(gcloud config get-value project)}"
ZONE=europe-west1-b
CLUSTER=ds-bench
echo "project=$PROJECT zone=$ZONE cluster=$CLUSTER"

# Cluster + server pool (default pool, NVMe local SSD for fast fsync)
gcloud container clusters describe "$CLUSTER" --zone "$ZONE" --project "$PROJECT" >/dev/null 2>&1 || \
gcloud container clusters create "$CLUSTER" --project "$PROJECT" --zone "$ZONE" \
  --num-nodes 1 --machine-type n2d-standard-8 \
  --ephemeral-storage-local-ssd count=1 \
  --node-labels=role=server --release-channel regular

# Client/worker pool (no SSD; scalable load generators)
gcloud container node-pools describe clients --cluster "$CLUSTER" --zone "$ZONE" --project "$PROJECT" >/dev/null 2>&1 || \
gcloud container node-pools create clients --cluster "$CLUSTER" --project "$PROJECT" --zone "$ZONE" \
  --machine-type n2d-standard-16 --num-nodes 2 --node-labels=role=client

# Artifact Registry docker repo
gcloud artifacts repositories describe ds-bench --location europe-west1 --project "$PROJECT" >/dev/null 2>&1 || \
gcloud artifacts repositories create ds-bench --repository-format=docker --location europe-west1 --project "$PROJECT"
gcloud auth configure-docker europe-west1-docker.pkg.dev --quiet

# Credentials + namespace
gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONE" --project "$PROJECT"
CTX="gke_${PROJECT}_${ZONE}_${CLUSTER}"
kubectl --context "$CTX" get ns ds-bench >/dev/null 2>&1 || kubectl --context "$CTX" create namespace ds-bench
echo "READY: context=$CTX namespace=ds-bench registry=europe-west1-docker.pkg.dev/$PROJECT/ds-bench"
```

- [ ] **Step 2: Write `scripts/gke-down.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
PROJECT="${1:-$(gcloud config get-value project)}"
gcloud container clusters delete ds-bench --zone europe-west1-b --project "$PROJECT" --quiet
echo "deleted cluster ds-bench (Artifact Registry repo kept; delete manually if desired)"
```

- [ ] **Step 3: Run + verify (the gate)** — `chmod +x scripts/gke-up.sh scripts/gke-down.sh && ./scripts/gke-up.sh`

Expected: prints `READY: context=... namespace=ds-bench ...`. Then verify:
`kubectl --context "$CTX" get nodes -L role` shows ≥1 `role=server` node and ≥2 `role=client` nodes, all `Ready`.

- [ ] **Step 4: Commit** — `git add scripts/gke-up.sh scripts/gke-down.sh && git commit -m "feat(gke): cluster + node pools + Artifact Registry bootstrap"`

---

### Task 2: ds-bench image with `mc`; push ds-bench + durable-streams to Artifact Registry

**Files:** Modify `dockerfiles/ds-bench.Dockerfile`; Create `scripts/gke-push-images.sh`.

**Interfaces:** Produces registry images `…/ds-bench/ds-bench:dev` (now bundling `mc`) and `…/ds-bench/durable-streams:dev`, amd64.

- [ ] **Step 1: Add `mc` to `dockerfiles/ds-bench.Dockerfile` runtime stage** (the fleet/coordinator use it to upload/download HDRs to MinIO):

```dockerfile
# in the debian:bookworm-slim runtime stage, after ca-certificates:
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc \
    && chmod +x /usr/local/bin/mc && rm -rf /var/lib/apt/lists/*
```
(Keep `ENTRYPOINT ["ds-bench"]`; the Job overrides `command` with a shell that runs ds-bench then `mc`.)

- [ ] **Step 2: Write `scripts/gke-push-images.sh`** (amd64 build + push)

```bash
#!/usr/bin/env bash
set -euo pipefail
PROJECT="${1:-$(gcloud config get-value project)}"
REG=europe-west1-docker.pkg.dev/$PROJECT/ds-bench
# ds-bench (amd64; build host is arm64 mac → use buildx --platform)
docker buildx build --platform linux/amd64 -f dockerfiles/ds-bench.Dockerfile -t "$REG/ds-bench:dev" --push ds-bench
# durable-streams (amd64)
docker buildx build --platform linux/amd64 -f dockerfiles/durable-streams.Dockerfile -t "$REG/durable-streams:dev" --push ../durable-streams
echo "pushed: $REG/ds-bench:dev  $REG/durable-streams:dev"
```
NOTE: the mac host is arm64, GKE nodes are amd64 — `--platform linux/amd64` + `buildx` is REQUIRED (cross-compile). Ensure `docker buildx` is available (`docker buildx version`); create a builder if needed (`docker buildx create --use`).

- [ ] **Step 2b: Build test** — `cargo build --release` in `ds-bench` still passes; `bash -n scripts/gke-push-images.sh`.

- [ ] **Step 3: Push + verify (the gate)** — `chmod +x scripts/gke-push-images.sh && ./scripts/gke-push-images.sh`
Expected: both images pushed. Verify: `gcloud artifacts docker images list europe-west1-docker.pkg.dev/$PROJECT/ds-bench` lists `ds-bench` and `durable-streams`. Confirm amd64: `docker buildx imagetools inspect $REG/ds-bench:dev | grep -i amd64`.

- [ ] **Step 4: Commit** — `git add dockerfiles/ds-bench.Dockerfile scripts/gke-push-images.sh && git commit -m "feat(gke): ds-bench image bundles mc; amd64 image push script"`

---

### Task 3: MinIO on GKE (NVMe `role=server` node)

**Files:** Create `gke/minio.yaml`.

**Interfaces:** Produces MinIO Service `minio:9000` in ns `ds-bench`, on the NVMe server node, with buckets `durable-streams` and `bench-results`.

- [ ] **Step 1: Write `gke/minio.yaml`** — adapt `k8s/minio.yaml` with: `namespace: ds-bench` on all objects, `nodeSelector: {role: server}` on the Deployment, data on an `emptyDir` (lands on the node's NVMe ephemeral storage) or `emptyDir: {medium: ""}` (NOT Memory), real resources (`requests cpu 500m mem 1Gi`, `limits mem 4Gi`), and a `minio-init` Job that creates BOTH `durable-streams` and `bench-results` buckets (`mc mb -p local/durable-streams local/bench-results`).

- [ ] **Step 2: Apply + verify (the gate)** —
```bash
kubectl --context "$CTX" -n ds-bench apply -f gke/minio.yaml
kubectl --context "$CTX" -n ds-bench wait --for=condition=complete job/minio-init --timeout=180s
kubectl --context "$CTX" -n ds-bench logs job/minio-init | tail -1   # expect: buckets-ready
kubectl --context "$CTX" -n ds-bench get pod -l app=minio -o wide      # confirm it's on a role=server node
```
Expected: `buckets-ready`; MinIO pod scheduled on the `role=server` node.

- [ ] **Step 3: Commit** — `git add gke/minio.yaml && git commit -m "feat(gke): MinIO on NVMe server node (durable-streams + bench-results buckets)"`

---

### Task 4: durable-streams Deployment on GKE (NVMe data-dir, MinIO tier)

**Files:** Create `gke/durable-streams.yaml`.

**Interfaces:** Produces Service `durable-streams:4438` in ns `ds-bench`, on the NVMe server node, data-dir on NVMe, offload to in-cluster MinIO.

- [ ] **Step 1: Write `gke/durable-streams.yaml`** — adapt `k8s/durable-streams.yaml`: `namespace: ds-bench`, image `europe-west1-docker.pkg.dev/<PROJECT>/ds-bench/durable-streams:dev` with `imagePullPolicy: Always` (replace `Never`), `nodeSelector: {role: server}`, mount an `emptyDir` (NVMe) at `/data`, args UNCHANGED (separate tokens, raw-only, `--tier s3 --tier-endpoint http://minio:9000 --tier-region us-east-1 --tier-bucket durable-streams --tier-allow-http`), env `DS_S3_*=minioadmin`, real resources (`requests cpu 2 mem 2Gi`, `limits mem 6Gi`). NOTE: replace `<PROJECT>` via `sed`/`envsubst` in the run scripts so it's not hardcoded.

- [ ] **Step 2: Apply + verify (the gate)** —
```bash
kubectl --context "$CTX" -n ds-bench apply -f gke/durable-streams.yaml   # (after substituting PROJECT)
kubectl --context "$CTX" -n ds-bench wait --for=condition=available deploy/durable-streams --timeout=180s
kubectl --context "$CTX" -n ds-bench run curlcheck --rm -i --restart=Never --image=curlimages/curl -- \
  sh -c 'curl -sS -X PUT http://durable-streams:4438/v1/stream/smoke -H "content-type: application/octet-stream" -o /dev/null -w "%{http_code}\n"'
```
Expected: `201`/`200`; pod on a `role=server` node (`-o wide`).

- [ ] **Step 3: Commit** — `git add gke/durable-streams.yaml && git commit -m "feat(gke): durable-streams on NVMe server node, MinIO offload"`

---

### Task 5: Cross-node fleet + coordinator via MinIO (THE central adaptation)

**Files:** Create `gke/bench-job.yaml`, `gke/coordinator-job.yaml`.

**Interfaces:** A multi-node fleet Job (on `role=client`) where each pod uploads its `.hdr`/`.json` to `s3://bench-results/<RUN_ID>/`; a coordinator Job that downloads the run prefix and runs `ds-bench hdr-merge`. Produces a merged JSON for a small multi-node run.

- [ ] **Step 1: Write `gke/bench-job.yaml`** — Indexed Job, `parallelism`/`completions` = N pods, `nodeSelector: {role: client}`, image `…/ds-bench:dev` (`imagePullPolicy: Always`). Env `DS_BENCH_HDR_OUT=/out`, `DS_BENCH_INSTANCE=$JOB_COMPLETION_INDEX` (via shell prefix, as in Phase 2a), `RUN_ID` (templated). `emptyDir` at `/out`. Command (shell):
```sh
DS_BENCH_INSTANCE="$JOB_COMPLETION_INDEX" ds-bench multi-stream --target http://durable-streams:4438 --api-style durable --streams 20 --duration-secs 15 --payload-bytes 256 > /out/ms-${JOB_COMPLETION_INDEX}.json
mc alias set local http://minio:9000 minioadmin minioadmin
mc cp --recursive /out/ "local/bench-results/${RUN_ID}/"
```
(Each pod uploads its own files under the run prefix — no shared volume needed; multi-node safe.)

- [ ] **Step 2: Write `gke/coordinator-job.yaml`** — `nodeSelector: {role: client}` (or server; any), image `…/ds-bench:dev`. Command:
```sh
mc alias set local http://minio:9000 minioadmin minioadmin
mc cp --recursive "local/bench-results/${RUN_ID}/" /merge/
ds-bench hdr-merge --hdr-dir /merge --results-dir /merge > /merge/merged.json && cat /merge/merged.json
```
`emptyDir` at `/merge`.

- [ ] **Step 3: Run a small MULTI-NODE fleet + verify exact merge (the gate)** — apply with `RUN_ID` substituted and `parallelism=4` so pods land across the 2 client nodes:
```bash
# (run scripts substitute RUN_ID + PROJECT)
kubectl --context "$CTX" -n ds-bench apply -f gke/bench-job.yaml
kubectl --context "$CTX" -n ds-bench wait --for=condition=complete job/bench-fleet --timeout=300s
kubectl --context "$CTX" -n ds-bench get pods -l job-name=bench-fleet -o wide   # confirm pods span ≥2 nodes
kubectl --context "$CTX" -n ds-bench apply -f gke/coordinator-job.yaml
kubectl --context "$CTX" -n ds-bench wait --for=condition=complete job/bench-coordinator --timeout=120s
kubectl --context "$CTX" -n ds-bench logs job/bench-coordinator
```
Expected: pods spread across both client nodes; coordinator's `merged_count` ≈ the SUM of all N pods' append counts (exact cross-node merge via MinIO — the Phase-2a RWO-PVC limitation is gone). Confirm `merged_count` > any single pod's count.

- [ ] **Step 4: Commit** — `git add gke/bench-job.yaml gke/coordinator-job.yaml && git commit -m "feat(gke): cross-node fleet + coordinator via MinIO upload/merge"`

---

### Task 6: `gke-run.sh` — one workload (one system) end-to-end on GKE

**Files:** Create `scripts/gke-run.sh`.

**Interfaces:** `gke-run.sh <system> <workload> [pods]` → deploys/ensures the server, runs the fleet (per-workload flags, like kind-run.sh), runs the coordinator, prints the merged JSON. Generates a unique `RUN_ID`.

- [ ] **Step 1: Write `scripts/gke-run.sh`** — `set -euo pipefail`; resolves `CTX`/`PROJECT`; per-workload command map (reuse kind-run.sh's `get_wl_cmd` logic — multi-stream/fan-out/catch-up/mixed with their correct flags); substitutes `PROJECT`/`RUN_ID`/`parallelism` into `gke/bench-job.yaml` (and the server target); applies fleet→coordinator; prints `== merged (<system>/<workload>) ==` + the coordinator log. For `mixed`, run the coordinator per class via `hdr-merge --label-prefix mixed-{write,fanout,read}` (as kind-run.sh does). Every kubectl `--context "$CTX" -n ds-bench`.

- [ ] **Step 2: Verify (the gate)** — `./scripts/gke-run.sh durable multi-stream 4` → prints a merged JSON with non-zero `merged_count`/`p99_ms`. Re-run `./scripts/gke-run.sh durable fan-out 4` and `… catch-up 4` → each merges.

- [ ] **Step 3: Commit** — `git add scripts/gke-run.sh && git commit -m "feat(gke): gke-run.sh single-workload end-to-end harness"`

**End of 2b.1: the GKE plumbing is proven — a multi-node client fleet, NVMe server, MinIO tiering, and exact cross-node HDR merge all work for DS-rust.**

---

## Phase 2b.2 — full matrix + sweeps + report

### Task 7: ds-bench per-workload headline metric (fix coordinator ops/s=0 for fan-out/catch-up)

**Files:** Modify `ds-bench/src/dist.rs`; Test `ds-bench/tests/hdr_roundtrip.rs`.

- [ ] **Step 1: Failing test** — add a test that a results dir containing a fan-out per-pod JSON (`events_received`, no `aggregate_ops_per_sec`) and a catch-up JSON (`aggregate_mb_per_sec`) yields a `MergeSummary` whose headline reflects events/sec and MB/s respectively (not `0.0`).
- [ ] **Step 2: Run → fails.**
- [ ] **Step 3: Implement** — extend `MergeSummary`/`sum_ops` so the coordinator reports the right headline per workload: sum `aggregate_ops_per_sec` (multi-stream/mixed), sum `events_received` → events/sec over duration (fan-out), sum `aggregate_mb_per_sec` / `bytes_received_total` (catch-up). Keep backward compatibility (multi-stream unchanged).
- [ ] **Step 4: Run → passes; `cargo build --release` clean.**
- [ ] **Step 5: Commit** — `fix(ds-bench): coordinator reports each workload's proper headline metric`.

### Task 8: Lift shared SSE/payload helpers into `sse_util.rs` (DRY)

**Files:** Create `ds-bench/src/sse_util.rs`; Modify `ds-bench/src/mixed.rs`, `main.rs`. Do NOT modify the verbatim `fanout.rs` (it stays byte-identical to upstream except its Task-1 emit line) — `mixed.rs` switches to `sse_util`; note the intentional remaining duplication in fanout.rs.

- [ ] **Step 1:** Move `build_payload`/`extract_send_ns`/`extract_send_ns_maybe_b64`/`find_event_end`/`parse_sse_data` (the mixed.rs copies, incl. the base64 fallback) into `sse_util.rs`; `mixed.rs` imports them. Add `mod sse_util;`.
- [ ] **Step 2: Verify** — `cargo build --release && cargo test`; a local mixed smoke still yields write/events/read all >0 + 3 hdr files (reuse Phase-2a smoke against a local durable-streams).
- [ ] **Step 3: Commit** — `refactor(ds-bench): shared sse_util for mixed (kills mixed/fanout helper drift)`.

### Task 9: DS-node server image + Deployment

**Files:** Create `dockerfiles/ds-node.Dockerfile`, `gke/ds-node.yaml`.

- [ ] **Step 1: Investigate** the Node/TS durable-streams server in `../durable-streams` (the package, start command, port, S3/tier env). Document the run command.
- [ ] **Step 2: Write `dockerfiles/ds-node.Dockerfile`** (node base; build/install the server package; expose its port). Add to `gke-push-images.sh`.
- [ ] **Step 3: Write `gke/ds-node.yaml`** — Deployment (registry image, `role=server`, NVMe data-dir if it persists locally, MinIO tier env) + Service `ds-node:<port>`.
- [ ] **Step 4: Verify (gate)** — deploy; in-cluster curl create/append/read roundtrip succeeds; `./scripts/gke-run.sh node multi-stream 4` merges (ds-bench `--api-style durable` against the Node server — confirm protocol parity; if the Node server's path/headers differ, capture and note).
- [ ] **Step 5: Commit** — `feat(gke): DS-node server image + deployment`.

### Task 10: ursula via Helm (1/3/5), matched durability

**Files:** Create `gke/ursula-values.yaml`.

- [ ] **Step 1:** From `vendor/ursula/charts/ursula`, write `gke/ursula-values.yaml` for matched durability: disk WAL Raft, cold tier → in-cluster MinIO (`endpoint http://minio:9000`, bucket, minioadmin), `role=server` nodeSelector, resources, and a `replicaCount`/topology knob for 1/3/5.
- [ ] **Step 2: Verify (gate)** — `helm --kube-context "$CTX" -n ds-bench install ursula vendor/ursula/charts/ursula -f gke/ursula-values.yaml` at replicas=1; wait ready; `./scripts/gke-run.sh ursula multi-stream 4` merges. Then scale to 3 and 5 (or reinstall) and confirm each comes up + a fleet run merges. Note: 3/5 nodes need ≥3/≥5 server-capable nodes — either grow the `role=server` pool for the ursula multi-node runs or use a dedicated ursula pool; document the node count used.
- [ ] **Step 3: Commit** — `feat(gke): ursula Helm values (disk WAL + MinIO cold tier, 1/3/5)`.

### Task 11: S2 Lite on GKE

**Files:** Create `gke/s2lite.yaml`.

- [ ] **Step 1: Write `gke/s2lite.yaml`** — Deployment from `ghcr.io/s2-streamstore/s2:latest` (public; `imagePullPolicy: Always`), `lite --bucket s2-bench --path s2lite --port 80`, env `AWS_ENDPOINT_URL_S3=http://minio:9000` + `AWS_ACCESS_KEY_ID/SECRET=minioadmin`, `role=server`; Service `s2lite:80`. Add `s2-bench` bucket to `gke/minio.yaml`'s init.
- [ ] **Step 2: Verify (gate)** — deploy; `./scripts/gke-run.sh s2 multi-stream 4` and `… fan-out 4` merge (S2 is excluded from catch-up/mixed — ds-bench bails, gke-run.sh must skip those for s2, like kind-run.sh).
- [ ] **Step 3: Commit** — `feat(gke): S2 Lite deployment (MinIO-backed)`.

### Task 12: Full matrix runner + saturation sweeps (`gke-matrix.sh`)

**Files:** Create `scripts/gke-matrix.sh`.

- [ ] **Step 1: Write `scripts/gke-matrix.sh`** — for each system (one server-under-test at a time: deploy → run → tear down server), run the applicable workloads with the sweeps: writes payload {100B,1KB,16KB}; fan-out subscribers {100,1k,10k}; **client-pod count scaled up** (e.g. 2→4→8→16) to find each server's saturation point; ursula at replicas {1,3,5}. S2 only write+fan-out. Each (system,workload,sweep-point) gets a unique `RUN_ID`; results land in `bench-results/<RUN_ID>/`, coordinator merges, output saved (download merged.json per run to a local `results/gke/` dir). Identical ds-bench params across systems per workload (fairness). Monitor client-pod CPU headroom (so the generator isn't the bottleneck) and log it.
- [ ] **Step 2: Verify (gate)** — a reduced matrix run (e.g. 2 systems × 1 workload × 2 pod-counts) completes and writes merged JSONs to `results/gke/`; spot-check a saturation point (more pods → higher aggregate throughput until it plateaus).
- [ ] **Step 3: Commit** — `feat(gke): full matrix runner with saturation + scale-out + subscriber sweeps`.

### Task 13: Report rendering — saturation / scale-out / fan-out curves

**Files:** Modify `scripts/render-results.py` (or add `scripts/render-gke.py`).

- [ ] **Step 1:** Read `results/gke/*/merged.json` (tagged by system/workload/sweep) and render: (a) per-system **saturation ceiling** (aggregate throughput + p99/p999 vs client-pod count), (b) **ursula scale-out** (throughput + tail vs server-node count 1/3/5), (c) **fan-out latency vs subscriber count**, (d) the single-node head-to-head table. Emit `results/gke/report.md` with the fairness/honesty disclosures (matched durability, group-commit symmetry, S2 substrate, MinIO-on-NVMe object tier, and the multi-node-vs-single-node SEPARATE-stories split).
- [ ] **Step 2: Verify (gate)** — run against the Task-12 reduced-matrix outputs; `results/gke/report.md` renders the curves/tables with the disclosures present.
- [ ] **Step 3: Commit** — `feat(gke): render saturation/scale-out/fan-out report with disclosures`.

### Task 14 (optional): kube-prometheus-stack dashboards

**Files:** notes only / a values file if pursued.

- [ ] Install kube-prometheus-stack via Helm for live run telemetry; merged-HDR JSON remains the authoritative source for the published numbers. Skip if not needed for the first run.

---

## Self-Review

**Spec coverage (Phase 2b):**
- Dedicated GKE cluster, two `n2d` pools (NVMe server + scalable clients), single-zone → Task 1. ✓
- Artifact Registry images (amd64), `imagePullPolicy: Always` → Tasks 2,4,9,11. ✓
- MinIO in-cluster on NVMe (not GCS), same for all → Tasks 3 + (s2 bucket) 11. ✓
- Cross-node results aggregation (RWO-PVC limitation solved via MinIO upload/merge) → Task 5 (explicit early gate). ✓
- nodeSelectors server vs client; real resources → Tasks 3,4,5,9,10,11. ✓
- Systems × topology (DS-rust 1, DS-node 1, ursula 1/3/5, S2 1; S2 write+fan-out only) → Tasks 4,9,10,11 + matrix 12. ✓
- Workloads + sweeps (payload, subscribers, client-pod saturation) → Task 12. ✓
- Headline outputs (saturation ceiling, ursula scale-out, fan-out vs subscribers, single-node head-to-head) + disclosures → Task 13. ✓
- Fairness/honesty (matched durability, group-commit, S2 substrate, MinIO-on-NVMe, multi-node SEPARATE stories) → Global Constraints + Task 13 disclosures. ✓
- GKE safety (dedicated context/namespace, never prod) → Global Constraints + every task's kubectl. ✓
- Carry-over fixes: coordinator headline metric → Task 7; SSE helper DRY → Task 8; mixed `--label-prefix` per-class → Task 6/12 (reused). ✓

**Phasing:** 2b.1 (Tasks 1-6) is the tractable first milestone — stand up the cluster/registry/MinIO/DS-rust and PROVE the cross-node HDR merge works end-to-end, the one genuinely new GKE risk. 2b.2 (Tasks 7-14) adds the other three systems, the per-workload metric + DRY fixes, the full sweep matrix, and the rendered report.

**Placeholder scan:** `<PROJECT>` and `RUN_ID`/`parallelism` are explicit runtime substitutions performed by the scripts (called out in the tasks), not left-in placeholders. The gcloud cluster create is billable and user-initiated (via `gke-up.sh`); tear down with `gke-down.sh`.

**Type/name consistency:** context `gke_<project>_europe-west1-b_ds-bench`, namespace `ds-bench`, registry `europe-west1-docker.pkg.dev/<PROJECT>/ds-bench`, buckets `durable-streams`/`bench-results`/`s2-bench`, labels `role=server`/`role=client`, run prefix `bench-results/<RUN_ID>/` — used consistently across Tasks 1-13.

**Deferred (Phase 3, not gaps):** DS-rust multi-node (true 3↔3 / 5↔5 vs ursula's replication); these are explicitly out of Phase 2b.
