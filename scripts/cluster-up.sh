#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# cluster-up.sh — bring up the cluster + namespace + metrics ConfigMap + MinIO
# for DS_TARGET. Idempotent: re-running on an existing cluster just re-applies.
#   local  → kind create cluster (single node).
#   remote → gcloud create: c4d-standard-16-lssd role=server (Titanium NVMe) +
#            clients pool (n2d-standard-16 ×2, role=client) on the `benchmarking` VPC.
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
    # c4d-8-lssd and c4d-16-lssd bundle the SAME single Titanium NVMe, so the
    # disk (the thing that matters for durability) is identical. The durable
    # server reserves only 500m (bursts to its 4-CPU limit), so 8 vCPU fits it +
    # MinIO + system. Pairs with ~64-pod fleets (MAX_FLEET_PODS). Override to
    # c4d-standard-16-lssd for 200-pod fleets / maximum measure isolation.
    SERVER_MACHINE="${SERVER_MACHINE:-c4d-standard-8-lssd}"
    # 4th-gen Titanium "-lssd" machines bundle a fixed Local SSD (the count is set
    # by the machine type — gcloud rejects an explicit count). Older N2D-style
    # types let you stripe N×375 GB devices via LOCAL_SSD_COUNT.
    case "$SERVER_MACHINE" in
      *-lssd) LSSD_FLAG=(--ephemeral-storage-local-ssd) ;;
      *)      LSSD_FLAG=(--ephemeral-storage-local-ssd "count=${LOCAL_SSD_COUNT:-1}") ;;
    esac
    gcloud container clusters create "$CLUSTER" --zone "$ZONE" --project "$PROJECT" --num-nodes 1 \
      --machine-type "$SERVER_MACHINE" "${LSSD_FLAG[@]}" \
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
