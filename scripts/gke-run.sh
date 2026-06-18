#!/usr/bin/env bash
# Run one workload (one system) end-to-end on the Phase-2b GKE cluster:
# substitute a unique RUN_ID + PROJECT + parallelism into the gke/ manifests,
# launch the multi-node ds-bench fleet (role=client), wait, then launch the
# coordinator which downloads every pod's HDR/JSON from MinIO and runs the
# exact cross-node hdr-merge. Prints the merged JSON.
#
# Usage: gke-run.sh <system> <workload> [pods]
#   system   : durable   (DS-rust; only system wired in 2b.1)
#   workload : multi-stream | fan-out | catch-up | mixed
#   pods     : fleet parallelism (default 4)
#
# Every kubectl call is scoped to the dedicated cluster context + namespace.
# bash 3.2 compatible (macOS): no associative arrays.
set -euo pipefail

SYSTEM="${1:?usage: gke-run.sh <system> <workload> [pods]}"
WORKLOAD="${2:?usage: gke-run.sh <system> <workload> [pods]}"
PARALLELISM="${3:-4}"

PROJECT="$(gcloud config get-value project 2>/dev/null)"
ZONE=europe-west1-b
CLUSTER=ds-bench
CTX="gke_${PROJECT}_${ZONE}_${CLUSTER}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
K() { kubectl --context "$CTX" -n ds-bench "$@"; }

RUN_ID="${WORKLOAD}-$(date +%s)-$$"

# --- resolve the server target (only DS-rust in 2b.1) ---
case "$SYSTEM" in
  durable) TARGET="http://durable-streams:4438"; API_STYLE="durable" ;;
  *) echo "ERROR: unknown system: $SYSTEM (2b.1 supports: durable)" >&2; exit 1 ;;
esac

# --- per-workload ds-bench command (mirrors kind-run.sh's get_wl_cmd) ---
case "$WORKLOAD" in
  multi-stream)
    BENCH_CMD="multi-stream --target ${TARGET} --api-style ${API_STYLE} --streams 20 --duration-secs 15 --payload-bytes 256"
    OUT_PREFIX="ms"
    ;;
  fan-out)
    BENCH_CMD="fan-out --target ${TARGET} --api-style ${API_STYLE} --subscribers 50 --writer-rate 50 --duration-secs 15 --payload-bytes 256"
    OUT_PREFIX="fan-out"
    ;;
  catch-up)
    BENCH_CMD="catch-up --target ${TARGET} --api-style ${API_STYLE} --clients 50 --pre-events 500 --event-bytes 256"
    OUT_PREFIX="catch-up"
    ;;
  mixed)
    BENCH_CMD="mixed --target ${TARGET} --api-style ${API_STYLE} --streams 4 --readers 4 --subscribers 4 --duration-secs 15"
    OUT_PREFIX="mixed"
    ;;
  *)
    echo "ERROR: unknown workload: $WORKLOAD" >&2; exit 1 ;;
esac

# --- per-workload merge command (mixed → per-class label-scoped merges) ---
if [ "$WORKLOAD" = "mixed" ]; then
  MERGE_CMD='echo "== merged (mixed / write) ==" && ds-bench hdr-merge --hdr-dir /merge --label-prefix mixed-write && echo "== merged (mixed / fanout) ==" && ds-bench hdr-merge --hdr-dir /merge --label-prefix mixed-fanout && echo "== merged (mixed / read) ==" && ds-bench hdr-merge --hdr-dir /merge --label-prefix mixed-read'
else
  MERGE_CMD='ds-bench hdr-merge --hdr-dir /merge --results-dir /merge'
fi

export PROJECT RUN_ID PARALLELISM BENCH_CMD OUT_PREFIX MERGE_CMD

echo "=== gke-run: system=${SYSTEM} workload=${WORKLOAD} pods=${PARALLELISM} run_id=${RUN_ID} ==="

# --- ensure the server is up (idempotent) ---
echo "  ensuring durable-streams server..."
envsubst '${PROJECT}' < gke/durable-streams.yaml | K apply -f -
K wait --for=condition=available deploy/durable-streams --timeout=300s

# --- clean prior jobs ---
K delete job bench-fleet bench-coordinator --ignore-not-found >/dev/null 2>&1 || true
# wait for old pods to clear
for _ in $(seq 1 30); do
  n=$(K get pods -l 'job-name in (bench-fleet,bench-coordinator)' --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" = "0" ] && break
  sleep 2
done

# --- launch fleet ---
echo "  launching fleet (${PARALLELISM} pods on role=client)..."
envsubst '${PROJECT} ${RUN_ID} ${PARALLELISM} ${BENCH_CMD} ${OUT_PREFIX}' < gke/bench-job.yaml | K apply -f -
K wait --for=condition=complete job/bench-fleet --timeout=600s
echo "  fleet pod placement:"
K get pods -l job-name=bench-fleet -o wide

# --- launch coordinator ---
echo "  launching coordinator..."
envsubst '${PROJECT} ${RUN_ID} ${MERGE_CMD}' < gke/coordinator-job.yaml | K apply -f -
K wait --for=condition=complete job/bench-coordinator --timeout=180s

echo ""
echo "== merged (${SYSTEM}/${WORKLOAD}) =="
K logs job/bench-coordinator
