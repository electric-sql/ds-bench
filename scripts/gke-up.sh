#!/usr/bin/env bash
# Idempotent GKE bootstrap for Track 2 Phase 2b: dedicated zonal cluster
# `ds-bench` (europe-west1-b) with a NVMe-backed role=server pool and a
# scalable role=client pool, an Artifact Registry docker repo, and the
# ds-bench namespace. Re-running when everything exists is a NO-OP.
#
# The cluster lives on the pre-existing `benchmarking` VPC so a fresh run
# reproduces the exact topology used in 2b.1.
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
  --node-labels=role=server --release-channel regular \
  --network benchmarking --subnetwork benchmarking

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
