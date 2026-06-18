# Phase 2b — GKE cluster setup runbook

Operational steps to stand up the dedicated GKE cluster for the Track 2 Phase 2b
(real-numbers) scale-out run. **These create billable resources** — the cluster
bills until you delete it (see Teardown). Run the interactive `gcloud auth login`
as `! gcloud auth login` in the agent prompt if you want its output captured.

## Decisions baked into this config (and why)

- **Dedicated, zonal cluster** in a single zone `europe-west1-b` — single zone ⇒
  all pods co-located ⇒ **no cross-zone egress** for fleet↔server traffic.
- **AMD `n2d`, x86/amd64** — cheapest GCP family that supports **Local NVMe SSD**
  (Arm `t2a` is cheaper per-vCPU but has no Local SSD). amd64 ⇒ no image-arch change.
- **Two node pools:**
  - `role=server` — `n2d-standard-8` + Local NVMe SSD. The server-under-test AND
    in-cluster MinIO schedule here, so their disk I/O (fsync, offload) is on NVMe.
  - `role=client` — `n2d-standard-16` ×2 (scalable). The `ds-bench` load-generator
    fleet runs here (CPU/network-bound).
- **Object store = in-cluster MinIO on the NVMe node** (NOT GCS). Same MinIO/config
  for every system ⇒ fair. (GCS-via-S3-compat was considered and deferred.) Disclose
  in the writeup: "object tier = in-cluster MinIO on local NVMe (near-best-case, not
  cloud-S3 latency)."
- **Never run against the `vaxine` prod context** — dedicated cluster + `ds-bench`
  namespace only.

## Prerequisites already satisfied
- Docker, `kubectl` v1.32, `kind`, `helm`, `brew` installed.
- `ghcr.io` public pull works (S2 Lite image) after `docker logout ghcr.io` removed a
  stale empty auth entry.

## Steps

### 1. Install gcloud + the GKE auth plugin
```bash
brew install --cask google-cloud-sdk
gcloud components install gke-gcloud-auth-plugin    # required for kubectl >= 1.26; if the cask blocks it: brew install gke-gcloud-auth-plugin
```

### 2. Authenticate (interactive — opens a browser)
```bash
gcloud auth login
```

### 3. Select project + enable APIs
```bash
gcloud config set project load-testing-2-438115        # dedicated load-testing project (confirm/change)
gcloud config set compute/zone europe-west1-b
gcloud services enable container.googleapis.com artifactregistry.googleapis.com
```

### 4. Create the cluster — server pool with NVMe (billable; ~5 min)
```bash
gcloud container clusters create ds-bench \
  --zone europe-west1-b --num-nodes 1 \
  --machine-type n2d-standard-8 \
  --ephemeral-storage-local-ssd count=1 \
  --node-labels=role=server \
  --release-channel regular
```

### 5. Add the client/worker pool
```bash
gcloud container node-pools create clients \
  --cluster ds-bench --zone europe-west1-b \
  --machine-type n2d-standard-16 --num-nodes 2 \
  --node-labels=role=client
```

### 6. Wire kubectl + create the namespace
```bash
gcloud container clusters get-credentials ds-bench --zone europe-west1-b
kubectl config current-context        # expect gke_load-testing-2-438115_europe-west1-b_ds-bench (NOT vaxine)
kubectl create namespace ds-bench
```

### 7. Artifact Registry (so GKE can pull our images)
```bash
gcloud artifacts repositories create ds-bench --repository-format=docker --location=europe-west1
gcloud auth configure-docker europe-west1-docker.pkg.dev
```
Images to push (amd64): `ds-bench`, `durable-streams`, and the Node `durable-streams`
server. `ursula` deploys via its Helm chart; S2 Lite pulls from public ghcr.

## Post-create verification (have the agent run these)
```bash
CTX=gke_load-testing-2-438115_europe-west1-b_ds-bench
kubectl --context "$CTX" get nodes -L role        # 1 server + 2 client nodes, role labels set
kubectl --context "$CTX" get node -l role=server -o jsonpath='{.items[0].status.allocatable}'   # NVMe ephemeral storage
kubectl --context "$CTX" get ns ds-bench
gcloud artifacts repositories describe ds-bench --location=europe-west1
```

## Cost + teardown
Rough on-demand cost ≈ ~$2/hr (1×n2d-standard-8 + 2×n2d-standard-16 + NVMe). Single
zone + everything in-cluster ⇒ no egress; you pay compute + small Artifact Registry
storage. **Delete when done:**
```bash
gcloud container clusters delete ds-bench --zone europe-west1-b
# optional: gcloud artifacts repositories delete ds-bench --location=europe-west1
```

## Next
After step 6, the agent verifies the cluster, then pushes images (step 7 + builds)
and adapts the manifests per the Phase 2b plan
(`docs/superpowers/plans/2026-06-18-track2-phase2b-gke.md`). Note the GKE-specific
change: per-pod HDR files go to in-cluster MinIO (not a single-node PVC), because the
client pool is multi-node and a ReadWriteOnce PVC can't span nodes.
