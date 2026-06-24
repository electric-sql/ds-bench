#!/usr/bin/env bash
# Build + push the amd64 ds-bench and durable-streams images to Artifact
# Registry using Google Cloud Build (native amd64 in GCP). This avoids QEMU
# emulation on the arm64 mac host — durable-streams' Rust LTO release build
# would take ~1h under `buildx --platform linux/amd64`; Cloud Build is fast
# and pushes straight to AR.
#
# The Dockerfiles live in dockerfiles/ but their build CONTEXTS differ
# (ds-bench -> ds-bench/ ; durable-streams -> ../durable-streams), so we copy
# each Dockerfile into its context root, submit that context, then remove the
# temporary copy.
set -euo pipefail
PROJECT="${1:-$(gcloud config get-value project)}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AR_LOCATION="${AR_LOCATION:-europe-west1}"; AR_REPO="${AR_REPO:-ds-bench}"
REG="${AR_LOCATION}-docker.pkg.dev/$PROJECT/$AR_REPO"
cd "$REPO_ROOT"

cleanup() {
  rm -f ds-bench/Dockerfile ../durable-streams/Dockerfile ../durable-streams/.dockerignore
}
trap cleanup EXIT

# --- ds-bench (context: ds-bench/) ---
echo "=== Cloud Build: ds-bench -> $REG/ds-bench:dev ==="
cp dockerfiles/ds-bench.Dockerfile ds-bench/Dockerfile
gcloud builds submit ds-bench --project "$PROJECT" --tag "$REG/ds-bench:dev"
rm -f ds-bench/Dockerfile

# --- durable-streams (context: ../durable-streams) ---
echo "=== Cloud Build: durable-streams -> $REG/durable-streams:dev ==="
cp dockerfiles/durable-streams.Dockerfile ../durable-streams/Dockerfile
gcloud builds submit ../durable-streams --project "$PROJECT" --tag "$REG/durable-streams:dev"
rm -f ../durable-streams/Dockerfile

# --- durable-node (Node.js reference; context: ../durable-streams; BUILD_NODE=0 to skip) ---
if [ "${BUILD_NODE:-1}" = 1 ]; then
  echo "=== Cloud Build: durable-node -> $REG/durable-node:dev ==="
  cp dockerfiles/durable-node.Dockerfile ../durable-streams/Dockerfile
  printf 'node_modules/\n.git/\ntarget/\n**/node_modules/\n**/target/\ndist/\n**/dist/\n' > ../durable-streams/.dockerignore
  gcloud builds submit ../durable-streams --project "$PROJECT" --tag "$REG/durable-node:dev"
  rm -f ../durable-streams/Dockerfile ../durable-streams/.dockerignore
fi

echo "pushed: $REG/ds-bench:dev  $REG/durable-streams:dev  $REG/durable-node:dev"
