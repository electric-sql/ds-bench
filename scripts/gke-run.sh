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
  ursula)  TARGET="http://ursula:4437";          API_STYLE="ursula"  ;;
  s2)      TARGET="http://s2lite:80";             API_STYLE="s2"      ;;
  *) echo "ERROR: unknown system: $SYSTEM (supported: durable | ursula | s2)" >&2; exit 1 ;;
esac

# S2 is its own substrate and is excluded from catch-up + mixed (the bench tool
# bails). Skip cleanly so the matrix can iterate without special-casing.
if [ "$SYSTEM" = "s2" ] && { [ "$WORKLOAD" = "catch-up" ] || [ "$WORKLOAD" = "mixed" ]; }; then
  echo "SKIP: s2 is excluded from $WORKLOAD (S2 runs multi-stream + fan-out only)"
  exit 0
fi

# --- per-workload ds-bench command (mirrors kind-run.sh's get_wl_cmd). The
# baseline flags are overridable via env so the matrix runner can drive a
# saturation sweep without forking the command map. ---
MS_STREAMS="${MS_STREAMS:-200}"
MS_DURATION="${MS_DURATION:-30}"
MS_PAYLOAD="${MS_PAYLOAD:-256}"
FO_SUBSCRIBERS="${FO_SUBSCRIBERS:-500}"
FO_RATE="${FO_RATE:-50}"
FO_DURATION="${FO_DURATION:-30}"
FO_PAYLOAD="${FO_PAYLOAD:-256}"
CU_CLIENTS="${CU_CLIENTS:-50}"
CU_PRE_EVENTS="${CU_PRE_EVENTS:-500}"
CU_EVENT_BYTES="${CU_EVENT_BYTES:-256}"
MX_STREAMS="${MX_STREAMS:-8}"
MX_READERS="${MX_READERS:-8}"
MX_SUBSCRIBERS="${MX_SUBSCRIBERS:-8}"
MX_DURATION="${MX_DURATION:-30}"

case "$WORKLOAD" in
  multi-stream)
    BENCH_CMD="multi-stream --target ${TARGET} --api-style ${API_STYLE} --streams ${MS_STREAMS} --duration-secs ${MS_DURATION} --payload-bytes ${MS_PAYLOAD}"
    OUT_PREFIX="ms"
    ;;
  fan-out)
    # Unique stream per run so a stale stream (created earlier with a different
    # content-type) cannot 409 "content-type mismatch" every append. fanout.rs
    # defaults --stream to a fixed "doc"; we override it. (Keeps fanout.rs
    # verbatim — the fix lives in the harness, not the forked file.)
    BENCH_CMD="fan-out --target ${TARGET} --api-style ${API_STYLE} --stream fo-${RUN_ID} --subscribers ${FO_SUBSCRIBERS} --writer-rate ${FO_RATE} --duration-secs ${FO_DURATION} --payload-bytes ${FO_PAYLOAD}"
    OUT_PREFIX="fan-out"
    ;;
  catch-up)
    BENCH_CMD="catch-up --target ${TARGET} --api-style ${API_STYLE} --stream cu-${RUN_ID} --clients ${CU_CLIENTS} --pre-events ${CU_PRE_EVENTS} --event-bytes ${CU_EVENT_BYTES}"
    OUT_PREFIX="catch-up"
    ;;
  mixed)
    BENCH_CMD="mixed --target ${TARGET} --api-style ${API_STYLE} --streams ${MX_STREAMS} --readers ${MX_READERS} --subscribers ${MX_SUBSCRIBERS} --duration-secs ${MX_DURATION}"
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

# --- ensure the server is up (idempotent). The matrix runner owns deploy/scale
# of one server-under-test at a time; set GKE_RUN_SKIP_SERVER=1 to skip this and
# assume the server is already up. Otherwise ensure the per-system server. ---
if [ "${GKE_RUN_SKIP_SERVER:-0}" != "1" ]; then
  case "$SYSTEM" in
    durable)
      echo "  ensuring durable-streams server..."
      envsubst '${PROJECT}' < gke/durable-streams.yaml | K apply -f -
      K wait --for=condition=available deploy/durable-streams --timeout=300s
      ;;
    ursula)
      echo "  ensuring ursula server..."
      envsubst '${PROJECT}' < gke/ursula.yaml | K apply -f -
      K wait --for=condition=available deploy/ursula --timeout=300s
      ;;
    s2)
      echo "  ensuring s2lite server..."
      K apply -f gke/s2lite.yaml
      K wait --for=condition=available deploy/s2lite --timeout=300s
      ;;
  esac
fi

# --- active in-cluster readiness probe of the server target ---
# tcpSocket readiness + rollout-status still return BEFORE the server actually
# handles HTTP requests (ursula's TCP listener binds early, but Raft/HTTP isn't
# serving yet → "connection refused" / reset on the fleet's first request). Poll
# the target from a CLIENT node (same network path as the fleet) and require
# THREE CONSECUTIVE successful HTTP responses (any code, even 404, means HTTP is
# truly serving) before launching the fleet. This is what stops ursula's
# first-run "connection refused".
PROBE_HOSTPORT="${TARGET#http://}"   # e.g. ursula:4437
echo "  probing server ${PROBE_HOSTPORT} (need 3 consecutive HTTP answers)..."
K run "server-probe-$$" --rm -i --restart=Never --image=curlimages/curl:latest \
  --overrides='{"spec":{"nodeSelector":{"role":"client"}}}' --command -- \
  /bin/sh -c "ok=0; for i in \$(seq 1 90); do code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://${PROBE_HOSTPORT}/ 2>/dev/null || echo 000); if [ \"\$code\" != \"000\" ]; then ok=\$((ok+1)); else ok=0; fi; if [ \"\$ok\" -ge 3 ]; then echo \"server serving (HTTP \$code, 3x)\"; exit 0; fi; sleep 1; done; echo 'server never served'; exit 1" \
  || { echo "  ERROR: server ${PROBE_HOSTPORT} never became ready" >&2; exit 1; }

# --- clean prior jobs (synchronously) — a previously interrupted run can leave a
# bench-fleet/bench-coordinator Job behind, and `apply` then fails with
# AlreadyExists. Delete and wait until BOTH the Job objects AND their pods are
# actually gone before launching. ---
K delete job bench-fleet bench-coordinator --ignore-not-found --wait=true >/dev/null 2>&1 || true
for _ in $(seq 1 45); do
  j=$(K get jobs bench-fleet bench-coordinator --no-headers 2>/dev/null | wc -l | tr -d ' ')
  p=$(K get pods -l 'job-name in (bench-fleet,bench-coordinator)' --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "$j" = "0" ] && [ "$p" = "0" ] && break
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
