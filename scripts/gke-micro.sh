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

echo "=== gke-micro: pulling results from MinIO into $OUT_DIR ==="

# Run a short-lived helper pod using the micro:dev image (which already has mc)
# to copy the results out of MinIO.  We exec the copy and capture stdout/stderr
# redirected to local files via kubectl logs after the pod completes.
#
# MinIO path written by the Job:  local/bench-results/micro-<RUN_ID>/
# We download results.jsonl, RESULTS.md, meta.txt (whatever is present).

K run "micro-pull-$$" \
  --rm \
  --restart=Never \
  --image="$REG/micro:dev" \
  --overrides='{"spec":{"nodeSelector":{"role":"server"}}}' \
  --command -- \
  bash -lc "
    mc alias set local http://minio:9000 minioadmin minioadmin 2>&1
    mc cp --recursive \"local/bench-results/micro-${RUN_ID}/\" /tmp/out/ 2>&1 && echo '__FILES_OK__'
    if [ -f /tmp/out/results.jsonl ]; then echo '---results.jsonl---'; cat /tmp/out/results.jsonl; fi
    if [ -f /tmp/out/RESULTS.md ];    then echo '---RESULTS.md---';    cat /tmp/out/RESULTS.md;    fi
    if [ -f /tmp/out/meta.txt ];      then echo '---meta.txt---';      cat /tmp/out/meta.txt;      fi
  " </dev/null > "$OUT_DIR/_raw_pull.txt" 2>&1 || true

# Parse the captured output into individual files
python3 - "$OUT_DIR/_raw_pull.txt" "$OUT_DIR" <<'PYEOF'
import sys, os, re

raw_file  = sys.argv[1]
out_dir   = sys.argv[2]

with open(raw_file) as f:
    content = f.read()

if '__FILES_OK__' not in content:
    print("WARN: mc copy may have failed — check " + raw_file, file=sys.stderr)

for marker, fname in [
    ('---results.jsonl---', 'results.jsonl'),
    ('---RESULTS.md---',    'RESULTS.md'),
    ('---meta.txt---',      'meta.txt'),
]:
    start = content.find(marker)
    if start == -1:
        continue
    start += len(marker) + 1          # skip the newline after marker
    # find next marker or end of string
    end_markers = [m for m, _ in [
        ('---results.jsonl---', ''), ('---RESULTS.md---', ''), ('---meta.txt---', ''),
    ] if m != marker]
    end = len(content)
    for em in end_markers:
        pos = content.find(em, start)
        if pos != -1 and pos < end:
            end = pos
    with open(os.path.join(out_dir, fname), 'w') as fout:
        fout.write(content[start:end].rstrip('\n') + '\n')
    print("  wrote " + fname)
PYEOF

echo "=== gke-micro: results written to $OUT_DIR ==="
if [ -f "$OUT_DIR/RESULTS.md" ]; then
  echo "  RESULTS.md: $OUT_DIR/RESULTS.md"
else
  echo "  WARN: RESULTS.md not found — see $OUT_DIR/_raw_pull.txt"
fi
