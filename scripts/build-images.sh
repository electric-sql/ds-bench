#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# build-images.sh — build the ds-bench + durable-streams images for DS_TARGET.
#   local  → native `docker build` (arm64 on Apple Silicon, no QEMU) + `kind load`
#            (no registry — fast dev loop).
#   remote → Cloud Build → Artifact Registry (scripts/gke-push-images.sh, amd64).
#
# The durable-streams image is built from ../durable-streams at its CURRENT
# checkout — so `git -C ../durable-streams checkout <branch>` then re-run this to
# iterate on the server.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=scripts/target-env.sh
. scripts/target-env.sh

if [ "$DS_TARGET" = "remote" ]; then
  echo "=== remote: Cloud Build → Artifact Registry ==="
  exec scripts/gke-push-images.sh "${PROJECT}"
fi

# ── local: native docker build + kind load ───────────────────────────────────
build_one() {  # tag dockerfile context
  local tag="$1" dockerfile="$2" context="$3" rc
  echo "=== docker build ${tag} (native) — context ${context} ==="
  cp "$dockerfile" "${context}/Dockerfile"
  printf 'target/\n.git/\nnode_modules/\n**/target/\n**/node_modules/\ndist/\n**/dist/\n' > "${context}/.dockerignore"
  if docker build -t "${tag}" "${context}"; then rc=0; else rc=$?; fi
  rm -f "${context}/Dockerfile" "${context}/.dockerignore"
  [ "$rc" = 0 ] || { echo "build ${tag} FAILED (rc=$rc)" >&2; exit "$rc"; }
}

build_one "ds-bench:dev"         dockerfiles/ds-bench.Dockerfile         ds-bench
build_one "durable-streams:dev"  dockerfiles/durable-streams.Dockerfile  ../durable-streams
# Node.js reference server (BUILD_NODE=0 to skip when iterating only on the Rust server).
loaded="durable-streams:dev ds-bench:dev"
if [ "${BUILD_NODE:-1}" = 1 ]; then
  build_one "durable-node:dev" dockerfiles/durable-node.Dockerfile ../durable-streams
  loaded="$loaded durable-node:dev"
fi

echo "=== kind load docker-image → ${KIND_CLUSTER} ==="
kind load docker-image $loaded --name "$KIND_CLUSTER"
echo "✓ images built + loaded ($(git -C ../durable-streams rev-parse --short HEAD 2>/dev/null) server)"
