#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# cluster-up.sh — bring up the cluster + namespace + metrics ConfigMap + MinIO
# for DS_TARGET. Idempotent: re-running on an existing cluster just re-applies.
#   local  → kind create cluster (single node).
#   remote → gcloud create: n2d-standard-8 role=server (NVMe) + clients pool
#            (n2d-standard-16 ×2, role=client) on the `benchmarking` VPC.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=scripts/lib-bench.sh
. scripts/lib-bench.sh   # sources target-env.sh; gives K() + ensure_metrics_configmap

if [ "$DS_TARGET" = "local" ]; then
  if kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
    echo "kind cluster '${KIND_CLUSTER}' already exists"
  else
    echo "=== kind create cluster --name ${KIND_CLUSTER} ==="
    kind create cluster --name "$KIND_CLUSTER"
  fi
else
  if gcloud container clusters describe "$CLUSTER" --zone "$ZONE" --project "$PROJECT" >/dev/null 2>&1; then
    echo "GKE cluster '${CLUSTER}' already exists"
  else
    echo "=== gcloud create cluster ${CLUSTER} (+ clients pool) ==="
    gcloud container clusters create "$CLUSTER" --zone "$ZONE" --project "$PROJECT" --num-nodes 1 \
      --machine-type n2d-standard-8 --ephemeral-storage-local-ssd count=1 \
      --node-labels=role=server --network benchmarking --subnetwork benchmarking \
      --enable-ip-alias --release-channel regular
    gcloud container node-pools create clients --cluster "$CLUSTER" --zone "$ZONE" --project "$PROJECT" \
      --machine-type n2d-standard-16 --num-nodes "${CLIENT_NODES:-2}" --node-labels=role=client
  fi
  gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONE" --project "$PROJECT"
  gcloud auth configure-docker europe-west1-docker.pkg.dev -q || true
fi

echo "=== namespace + metrics ConfigMap + MinIO (context=${KCTX}) ==="
kubectl --context "$KCTX" create namespace ds-bench --dry-run=client -o yaml | kubectl --context "$KCTX" apply -f -
ensure_metrics_configmap
envsubst "$MANIFEST_VARS" < gke/minio.yaml | K apply -f -
K wait --for=condition=available deploy/minio --timeout=180s 2>/dev/null \
  || echo "WARN: minio not yet available — check 'K get pods'"
echo "✓ cluster-up complete (target=${DS_TARGET}, context=${KCTX})"
