#!/usr/bin/env bash
# Run the `sustained` workload across a STREAM-COUNT SWEEP (or `multi-fanout`
# as a single run) on the Phase-2b GKE cluster.  Also deploys the durable-streams
# server WITH the metrics sidecar and collects per-N RSS/CPU time series.
#
# Usage: gke-sustained.sh <system> [workload] [stream-counts...]
#   system       : durable | ursula | s2
#   workload     : sustained (default) | multi-fanout
#   stream-counts: space-separated list (default: 10 100 1000 10000)
#                  ignored for multi-fanout (single run)
#
# Every kubectl call is scoped to the dedicated cluster context + namespace.
# bash 3.2 compatible (macOS): no associative arrays.
set -euo pipefail

SYSTEM="${1:?usage: gke-sustained.sh <system> [workload] [stream-counts...]}"
WORKLOAD="${2:-sustained}"
shift 2 || shift 1 || true   # consume system + workload; remainder = stream counts

PROJECT="$(gcloud config get-value project 2>/dev/null)"
ZONE=europe-west1-b
CLUSTER=ds-bench
CTX="gke_${PROJECT}_${ZONE}_${CLUSTER}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
K() { kubectl --context "$CTX" -n ds-bench "$@"; }

PARALLELISM="${PARALLELISM:-4}"

# --- validate workload ---
case "$WORKLOAD" in
  sustained|multi-fanout) ;;
  *) echo "ERROR: unknown workload: $WORKLOAD (supported: sustained | multi-fanout)" >&2; exit 1 ;;
esac

# --- resolve the server target ---
case "$SYSTEM" in
  durable) TARGET="http://durable-streams:4438"; API_STYLE="durable" ;;
  ursula)  TARGET="http://ursula:4437";          API_STYLE="ursula"  ;;
  s2)      TARGET="http://s2lite:80";             API_STYLE="s2"      ;;
  *) echo "ERROR: unknown system: $SYSTEM (supported: durable | ursula | s2)" >&2; exit 1 ;;
esac

# --- stream-count sweep defaults (only used for sustained) ---
if [ "$#" -gt 0 ]; then
  STREAM_COUNTS="$*"
else
  STREAM_COUNTS="10 100 1000 10000"
fi

# --- per-workload tuning knobs (overridable via env) ---
RATE="${RATE:-50}"
DURATION="${DURATION:-300}"
M="${M:-100}"          # multi-fanout: streams
S="${S:-10}"           # multi-fanout: subscribers-per-stream

echo "=== gke-sustained: system=${SYSTEM} workload=${WORKLOAD} pods=${PARALLELISM} ==="

# ─── Step 1: create the metrics-poller ConfigMap (idempotent, before server) ──
echo "  creating metrics-poller ConfigMap from deploy/metrics/poller.sh..."
K create configmap metrics-poller \
  --from-file=poller.sh=deploy/metrics/poller.sh \
  --dry-run=client -o yaml | K apply -f -

# ─── Step 2: deploy server WITH sidecar ───────────────────────────────────────
if [ "${GKE_RUN_SKIP_SERVER:-0}" != "1" ]; then
  case "$SYSTEM" in
    durable)
      echo "  ensuring durable-streams server (with metrics sidecar)..."
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

# --- active in-cluster readiness probe (same pattern as gke-run.sh) ---
PROBE_HOSTPORT="${TARGET#http://}"
echo "  probing server ${PROBE_HOSTPORT} (need 3 consecutive HTTP answers)..."
K run "server-probe-$$" --rm --attach --restart=Never --image=curlimages/curl:latest \
  --overrides='{"spec":{"nodeSelector":{"role":"client"}}}' --command -- \
  /bin/sh -c "ok=0; for i in \$(seq 1 90); do code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://${PROBE_HOSTPORT}/ 2>/dev/null); case \"\$code\" in 2??|3??|4??|5??) ok=\$((ok+1));; *) ok=0;; esac; if [ \"\$ok\" -ge 3 ]; then echo \"server serving (HTTP \$code, 3x)\"; exit 0; fi; sleep 1; done; echo 'server never served'; exit 1" </dev/null \
  && echo "  probe ok" || echo "  WARN: probe wrapper returned non-zero (kubectl --rm attach is flaky); continuing"

# ─── helper: clean prior jobs synchronously (AlreadyExists guard) ─────────────
clean_jobs() {
  K delete job bench-fleet bench-coordinator --ignore-not-found --wait=true >/dev/null 2>&1 || true
  for _ in $(seq 1 45); do
    j=$( { K get jobs bench-fleet bench-coordinator --no-headers 2>/dev/null || true; } | wc -l | tr -d ' ')
    p=$( { K get pods -l 'job-name in (bench-fleet,bench-coordinator)' --no-headers 2>/dev/null || true; } | wc -l | tr -d ' ')
    if [ "$j" = "0" ] && [ "$p" = "0" ]; then break; fi
    sleep 2
  done
}

# ─── helper: run fleet → coordinator for a given RUN_ID/BENCH_CMD/OUT_PREFIX/MERGE_CMD
run_fleet_and_coordinator() {
  export PROJECT RUN_ID PARALLELISM BENCH_CMD OUT_PREFIX MERGE_CMD

  # clean leftover jobs
  clean_jobs

  # launch fleet
  echo "    launching fleet (${PARALLELISM} pods on role=client)..."
  envsubst '${PROJECT} ${RUN_ID} ${PARALLELISM} ${BENCH_CMD} ${OUT_PREFIX}' < gke/bench-job.yaml | K apply -f -
  K wait --for=condition=complete job/bench-fleet --timeout=600s
  echo "    fleet pod placement:"
  K get pods -l job-name=bench-fleet -o wide

  # clean coordinator leftover then launch
  echo "    launching coordinator..."
  K delete job bench-coordinator --ignore-not-found --wait=true >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    c=$( { K get job bench-coordinator --no-headers 2>/dev/null || true; } | wc -l | tr -d ' ')
    if [ "$c" = "0" ]; then break; fi
    sleep 2
  done
  envsubst '${PROJECT} ${RUN_ID} ${MERGE_CMD}' < gke/coordinator-job.yaml | K apply -f -
  K wait --for=condition=complete job/bench-coordinator --timeout=180s
}

# ─── Step 3a: sustained sweep ─────────────────────────────────────────────────
if [ "$WORKLOAD" = "sustained" ]; then
  SWEEP_RUN_ID="sustained-$(date +%s)-$$"
  echo "  sweep run_id base: ${SWEEP_RUN_ID}"

  for N in $STREAM_COUNTS; do
    RUN_ID="${SWEEP_RUN_ID}-n${N}"
    echo ""
    echo "=== sustained N=${N} run_id=${RUN_ID} ==="

    # Truncate the per-N samples.csv so this N's window only contains its own data.
    case "$SYSTEM" in
      durable) _RESET_LABEL="app=durable-streams" ;;
      ursula)  _RESET_LABEL="app=ursula" ;;
      s2)      _RESET_LABEL="app=s2lite" ;;
    esac
    _RESET_POD="$( { K get pod -l "$_RESET_LABEL" -o name 2>/dev/null || true; } | head -1 | sed 's|pod/||')"
    if [ -n "$_RESET_POD" ] && [ "$SYSTEM" = "durable" ]; then
      echo "    resetting samples.csv on pod ${_RESET_POD} before N=${N}..."
      K exec "$_RESET_POD" -c metrics -- sh -c 'echo "ts_ms,rss_bytes,cpu_ticks" > /metrics/samples.csv' \
        || true  # transient exec failure must not abort the sweep
    fi

    BENCH_CMD="sustained --target ${TARGET} --api-style ${API_STYLE} --streams ${N} --rate-per-stream ${RATE} --duration-secs ${DURATION} --snapshot-secs 5"
    OUT_PREFIX="sustained"
    MERGE_CMD="ds-bench hdr-merge --hdr-dir /merge --results-dir /merge --label-prefix sustained-"

    run_fleet_and_coordinator

    # --- collect merged JSON from coordinator logs ---
    RESULT_DIR="results/sustained/${SWEEP_RUN_ID}/${N}"
    mkdir -p "$RESULT_DIR"
    K logs job/bench-coordinator > "${RESULT_DIR}/merged.json"
    echo "    saved merged.json → ${RESULT_DIR}/merged.json"

    # --- collect sidecar samples.csv from server pod ---
    # get the pod name for the durable-streams server (label app= per system)
    case "$SYSTEM" in
      durable) SERVER_LABEL="app=durable-streams" ;;
      ursula)  SERVER_LABEL="app=ursula" ;;
      s2)      SERVER_LABEL="app=s2lite" ;;
    esac
    SERVER_POD="$( { K get pod -l "$SERVER_LABEL" -o name 2>/dev/null || true; } | head -1 | sed 's|pod/||')"
    if [ -n "$SERVER_POD" ] && [ "$SYSTEM" = "durable" ]; then
      echo "    collecting sidecar metrics from pod ${SERVER_POD} container metrics..."
      K cp "ds-bench/${SERVER_POD}:/metrics/samples.csv" "${RESULT_DIR}/samples.csv" -c metrics \
        && echo "    saved samples.csv → ${RESULT_DIR}/samples.csv" \
        || echo "    WARN: could not copy samples.csv (sidecar may not be running for system=${SYSTEM})"
    else
      echo "    skipping sidecar collection (system=${SYSTEM} has no metrics container)"
    fi

    echo "    N=${N} done."
  done

  echo ""
  echo "=== sustained sweep complete. Results in results/sustained/${SWEEP_RUN_ID}/ ==="

# ─── Step 3b: multi-fanout single run ─────────────────────────────────────────
elif [ "$WORKLOAD" = "multi-fanout" ]; then
  RUN_ID="multi-fanout-$(date +%s)-$$"
  echo "  run_id: ${RUN_ID}"

  BENCH_CMD="multi-fanout --target ${TARGET} --api-style ${API_STYLE} --streams ${M} --subscribers-per-stream ${S} --writer-rate ${RATE} --duration-secs ${DURATION}"
  OUT_PREFIX="multi-fanout"
  MERGE_CMD="ds-bench hdr-merge --hdr-dir /merge --results-dir /merge --label-prefix multi-fanout-"

  run_fleet_and_coordinator

  # --- collect merged JSON ---
  RESULT_DIR="results/multi-fanout/${RUN_ID}"
  mkdir -p "$RESULT_DIR"
  K logs job/bench-coordinator > "${RESULT_DIR}/merged.json"
  echo "  saved merged.json → ${RESULT_DIR}/merged.json"

  echo ""
  echo "=== multi-fanout run complete. Results in ${RESULT_DIR}/ ==="
fi
