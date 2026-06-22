#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# gke-sustained.sh — Phase 3: sustained load + memory stability.
#   `sustained` over a STREAM-COUNT SWEEP (RSS drift over time), or `multi-fanout`
#   as a single run. Engine (K, deploy_server, run_fleet_and_coordinator, sidecar
#   collect) lives in scripts/lib-bench.sh; this file is the Phase-3 sweep only.
#
# Usage:  [DS_TARGET=local|remote] scripts/gke-sustained.sh <system> [workload] [N...]
#   system   : durable (local+remote) | ursula | s2 (comparison systems, REMOTE only)
#   workload : sustained (default) | multi-fanout
#   N...     : stream counts (default "10 50 100 150"); ignored for multi-fanout
# Env knobs: PARALLELISM RATE DURATION SETUP_CONCURRENCY M S
#            FLEET_TIMEOUT COORD_TIMEOUT DS_TARGET.  (server is fixed 8-core/16 GB)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SYSTEM="${1:?usage: gke-sustained.sh <system> [workload] [stream-counts...]}"
WORKLOAD="${2:-sustained}"
shift 2 2>/dev/null || shift 1 2>/dev/null || true   # remainder = stream counts

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=scripts/lib-bench.sh
. scripts/lib-bench.sh    # sources target-env.sh; defines K() + the engine

PARALLELISM="${PARALLELISM:-4}"
SERVER_CPUS="8"; export SERVER_MEM="16Gi"   # server FIXED at 8 cores / 16 GB — never swept
MAX_BUMPS="${MAX_BUMPS:-0}"            # accepted for env parity; no bump loop here
REPEATS="${REPEATS:-1}"

case "$WORKLOAD" in
  sustained|multi-fanout) ;;
  *) echo "ERROR: unknown workload: $WORKLOAD (sustained | multi-fanout)" >&2; exit 1 ;;
esac

case "$SYSTEM" in
  durable) TARGET="http://durable-streams:4438"; API_STYLE="durable" ;;
  ursula)  TARGET="http://ursula:4437";          API_STYLE="ursula"  ;;
  s2)      TARGET="http://s2lite:80";             API_STYLE="s2"      ;;
  *) echo "ERROR: unknown system: $SYSTEM (durable | ursula | s2)" >&2; exit 1 ;;
esac
PROBE_HOSTPORT="${TARGET#http://}"
if [ "$SYSTEM" != "durable" ] && [ "$DS_TARGET" = "local" ]; then
  echo "ERROR: system=${SYSTEM} is a comparison system — REMOTE only (its manifest is not templatized for local kind). Use DS_TARGET=remote." >&2
  exit 2
fi

# Stream-count sweep (sustained only). Kept modest: conns ≈ N × PARALLELISM.
if [ "$#" -gt 0 ]; then STREAM_COUNTS="$*"; else STREAM_COUNTS="${STREAM_COUNTS:-10 50 100 150}"; fi
RATE="${RATE:-10}"                     # per-stream ops/sec
DURATION="${DURATION:-90}"             # long, so the RSS sidecar captures drift
SETUP_CONCURRENCY="${SETUP_CONCURRENCY:-32}"   # bound the concurrent create burst
M="${M:-10}"; S="${S:-10}"             # multi-fanout: streams × subscribers

echo "=== gke-sustained: system=${SYSTEM} workload=${WORKLOAD} target=${DS_TARGET} pods=${PARALLELISM} ==="

ensure_metrics_configmap

# ── deploy server ────────────────────────────────────────────────────────────
if [ "${GKE_RUN_SKIP_SERVER:-0}" != "1" ]; then
  case "$SYSTEM" in
    durable)
      deploy_server "$SERVER_CPUS"   # lib: target-aware deploy + wait + probe
      ;;
    ursula)
      echo "  ensuring ursula server (remote)..."
      envsubst '${PROJECT}' < gke/ursula.yaml | K apply -f -
      K wait --for=condition=available deploy/ursula --timeout=300s
      ;;
    s2)
      echo "  ensuring s2lite server (remote)..."
      K apply -f gke/s2lite.yaml
      K wait --for=condition=available deploy/s2lite --timeout=300s
      ;;
  esac
  if [ "$SYSTEM" != "durable" ]; then
    echo "  probing ${PROBE_HOSTPORT} (need 3 consecutive HTTP answers)..."
    K run "server-probe-$$" --rm --attach --restart=Never --image=curlimages/curl:latest \
      --overrides="{\"spec\":{\"nodeSelector\":${NODESEL_CLIENT}}}" --command -- \
      /bin/sh -c "ok=0; for i in \$(seq 1 90); do code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://${PROBE_HOSTPORT}/ 2>/dev/null); case \"\$code\" in 2??|3??|4??|5??) ok=\$((ok+1));; *) ok=0;; esac; if [ \"\$ok\" -ge 3 ]; then echo \"serving (HTTP \$code, 3x)\"; exit 0; fi; sleep 1; done; exit 1" </dev/null \
      && echo "  probe ok" || echo "  WARN: probe non-zero (kubectl --rm attach is flaky); continuing"
  fi
fi

# ── sustained sweep ──────────────────────────────────────────────────────────
if [ "$WORKLOAD" = "sustained" ]; then
  SWEEP_RUN_ID="sustained-$(date +%s)-$$"
  echo "  sweep run_id base: ${SWEEP_RUN_ID}"
  for N in $STREAM_COUNTS; do
    RUN_ID="${SWEEP_RUN_ID}-n${N}"
    echo ""
    echo "=== sustained N=${N} run_id=${RUN_ID} ==="
    reset_sidecar_samples   # lib: truncate the durable sidecar CSV (no-op for ursula/s2)

    BENCH_CMD="sustained --target ${TARGET} --api-style ${API_STYLE} --streams ${N} --rate-per-stream ${RATE} --duration-secs ${DURATION} --snapshot-secs 5 --setup-concurrency ${SETUP_CONCURRENCY}"
    OUT_PREFIX="sustained"
    MERGE_CMD="ds-bench hdr-merge --hdr-dir /merge --results-dir /merge --label-prefix sustained-"
    run_fleet_and_coordinator   # lib

    RESULT_DIR="results/sustained/${SWEEP_RUN_ID}/${N}"
    mkdir -p "$RESULT_DIR"
    K logs job/bench-coordinator > "${RESULT_DIR}/merged.json"
    echo "    saved merged.json → ${RESULT_DIR}/merged.json"
    collect_sidecar "$RESULT_DIR"   # lib: durable only; warns+skips otherwise
    echo "    N=${N} done."
  done
  echo ""
  echo "=== sustained sweep complete. Results in results/sustained/${SWEEP_RUN_ID}/ ==="

# ── multi-fanout single run ──────────────────────────────────────────────────
elif [ "$WORKLOAD" = "multi-fanout" ]; then
  RUN_ID="multi-fanout-$(date +%s)-$$"
  echo "  run_id: ${RUN_ID}"
  BENCH_CMD="multi-fanout --target ${TARGET} --api-style ${API_STYLE} --streams ${M} --subscribers-per-stream ${S} --writer-rate ${RATE} --duration-secs ${DURATION} --setup-concurrency ${SETUP_CONCURRENCY}"
  OUT_PREFIX="multi-fanout"
  MERGE_CMD="ds-bench hdr-merge --hdr-dir /merge --results-dir /merge --label-prefix multi-fanout-"
  run_fleet_and_coordinator   # lib

  RESULT_DIR="results/multi-fanout/${RUN_ID}"
  mkdir -p "$RESULT_DIR"
  K logs job/bench-coordinator > "${RESULT_DIR}/merged.json"
  echo "  saved merged.json → ${RESULT_DIR}/merged.json"
  echo ""
  echo "=== multi-fanout run complete. Results in ${RESULT_DIR}/ ==="
fi
