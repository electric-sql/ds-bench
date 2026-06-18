#!/usr/bin/env bash
# Build + push the micro benchmark image, run the dedicated micro Job on GKE,
# wait for completion, and pull results from MinIO into results/micro/<RUN_ID>/.
#
# Pre-requisite: cluster must be up (run scripts/gke-up.sh first).
#
# Usage:
#   PROFILE=fast   scripts/gke-micro.sh   # fast profile (~30 min)
#   PROFILE=full   scripts/gke-micro.sh   # full autobench (~90 min)
#
# Build context assembled here (cannot use buildx/QEMU — native amd64 via GCB):
#   <stage>/                 ← durable-streams checkout at root  (cp -R ../durable-streams/.)
#   <stage>/micro/           ← this repo's micro/ subdir
#   <stage>/Dockerfile       ← dockerfiles/micro.Dockerfile
#
# Every kubectl call is scoped to the ds-bench cluster context + namespace.
# bash 3.2 compatible (macOS): no associative arrays.
set -euo pipefail

PROFILE="${PROFILE:-fast}"

PROJECT="$(gcloud config get-value project 2>/dev/null)"
ZONE=europe-west1-b
CLUSTER=ds-bench
CTX="gke_${PROJECT}_${ZONE}_${CLUSTER}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
REG="europe-west1-docker.pkg.dev/$PROJECT/ds-bench"

K() { kubectl --context "$CTX" -n ds-bench "$@"; }

# GCS object store (S3-compatible HMAC creds). The Job uploads results here via
# `mc`; the local pull below uses user-authed `gcloud storage` (no HMAC needed
# locally). Override via env. Secret `gcs-hmac` is (re)created before the Job.
GCS_BUCKET="${GCS_BUCKET:-vaxine-ds-bench-tier}"
: "${GCS_HMAC_KEY:?set GCS_HMAC_KEY (GCS HMAC access id)}"
: "${GCS_HMAC_SECRET:?set GCS_HMAC_SECRET (GCS HMAC secret)}"

# ---------------------------------------------------------------------------
# 1.  Build + push micro:dev via Cloud Build
# ---------------------------------------------------------------------------

STAGE="$(mktemp -d)"
cleanup_stage() { rm -rf "$STAGE"; }
trap cleanup_stage EXIT

echo "=== gke-micro: assembling build context in $STAGE ==="

# durable-streams source at context root (exclude .git and target for speed)
rsync -a --exclude='.git' --exclude='target' "$REPO_ROOT/../durable-streams/" "$STAGE/"

# micro/ subdir alongside it
cp -R "$REPO_ROOT/micro" "$STAGE/micro"

# Dockerfile at context root
cp "$REPO_ROOT/dockerfiles/micro.Dockerfile" "$STAGE/Dockerfile"

echo "=== Cloud Build: micro -> $REG/micro:dev ==="
gcloud builds submit "$STAGE" --project "$PROJECT" --tag "$REG/micro:dev"

# Temp dir is cleaned by the trap above after submit returns.

# ---------------------------------------------------------------------------
# 2.  Generate RUN_ID, substitute into the Job manifest, apply
# ---------------------------------------------------------------------------

RUN_ID="micro-$(date +%s)-$$"
echo "=== gke-micro: run_id=${RUN_ID} profile=${PROFILE} ==="

# Clean any prior micro job (synchronously)
K delete job micro --ignore-not-found --wait=true >/dev/null 2>&1 || true

# Substitute REPLACE_RUN_ID and PROFILE into the manifest
MICRO_MANIFEST="$(mktemp)"
cleanup_manifest() { rm -f "$MICRO_MANIFEST"; }
# Chain both cleanups; override the trap to run both
trap 'cleanup_stage; cleanup_manifest' EXIT

sed \
  -e "s/REPLACE_RUN_ID/${RUN_ID}/g" \
  -e "s/value: \"fast\"/value: \"${PROFILE}\"/" \
  "$REPO_ROOT/gke/micro-job.yaml" > "$MICRO_MANIFEST"

# (Re)create the GCS HMAC secret the Job mounts for the `mc` results upload.
K delete secret gcs-hmac --ignore-not-found >/dev/null 2>&1 || true
K create secret generic gcs-hmac \
  --from-literal=access_id="$GCS_HMAC_KEY" \
  --from-literal=secret="$GCS_HMAC_SECRET"

K apply -f "$MICRO_MANIFEST"

# ---------------------------------------------------------------------------
# 3.  Wait for Job completion
# ---------------------------------------------------------------------------

echo "=== gke-micro: waiting for job/micro (timeout 7200s) ==="
# Watch for failure in parallel so a backoffLimit:0 failure doesn't hang 7200s.
K wait --for=condition=failed job/micro --timeout=7200s \
  && { echo "ERROR: micro job FAILED"; K logs job/micro | tail -50; exit 1; } &
FAIL_WATCHER_PID=$!
K wait --for=condition=complete job/micro --timeout=7200s
# Job completed successfully — kill the failure watcher.
kill "$FAIL_WATCHER_PID" 2>/dev/null; wait "$FAIL_WATCHER_PID" 2>/dev/null || true

echo "=== gke-micro: job/micro complete ==="

# ---------------------------------------------------------------------------
# 4.  Pull results from MinIO into results/micro/<RUN_ID>/
# ---------------------------------------------------------------------------

OUT_DIR="$REPO_ROOT/results/micro/$RUN_ID"
mkdir -p "$OUT_DIR"

echo "=== gke-micro: pulling results from GCS into $OUT_DIR ==="

# GCS path written by the Job:  gs://<bucket>/micro-<RUN_ID>/
# The local gcloud is user-authed (no HMAC needed here). Strip the inner
# timestamp dir the suite writes (out/<STAMP>/...) into $OUT_DIR.
gcloud storage cp --recursive \
  "gs://${GCS_BUCKET}/micro-${RUN_ID}/*" "$OUT_DIR/" 2>&1 || \
  echo "WARN: gcloud storage pull failed — check gs://${GCS_BUCKET}/micro-${RUN_ID}/"

# The suite uploads /micro/out/ which contains a <STAMP>/ subdir; flatten the
# key files (RESULTS.md, results.jsonl, meta.txt) up to $OUT_DIR if nested.
for f in RESULTS.md results.jsonl meta.txt run.log; do
  if [ ! -f "$OUT_DIR/$f" ]; then
    found="$(find "$OUT_DIR" -name "$f" -type f 2>/dev/null | head -1)"
    [ -n "$found" ] && cp "$found" "$OUT_DIR/$f"
  fi
done

echo "=== gke-micro: results written to $OUT_DIR ==="
if [ -f "$OUT_DIR/RESULTS.md" ]; then
  echo "  RESULTS.md: $OUT_DIR/RESULTS.md"
else
  echo "  WARN: RESULTS.md not found — see $OUT_DIR/_raw_pull.txt"
fi
