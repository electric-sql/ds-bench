#!/usr/bin/env bash
# gke-smoke.sh — quick smoke test of competitor systems (Ursula, S2-lite) under
# the SAME multi-stream benchmark, on an already-running cluster. Deploys each
# server, runs ONE short multi-stream cell, prints throughput. Reuses lib-bench
# (deploy_server for ursula; manual apply for s2). Does NOT create/tear down the
# cluster. For an apples-to-apples baseline vs durable-streams.
#
#   [STREAMS=1000] [PODS=2] [DUR=15] [SYSTEMS="ursula s2"] \
#     CLUSTER=ds-bench-fresh ZONE=europe-west4-a scripts/gke-smoke.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$(pwd)"; export REPO_ROOT
export DS_TARGET=remote PROJECT="${PROJECT:-vaxine}" ZONE="${ZONE:-europe-west4-a}" CLUSTER="${CLUSTER:-ds-bench-fresh}"
export SERVER_CPUS=4 SERVER_MEM=16Gi
# shellcheck source=scripts/lib-bench.sh
. scripts/lib-bench.sh

STREAMS="${STREAMS:-1000}"; PODS="${PODS:-2}"; DUR="${DUR:-15}"; SYSTEMS="${SYSTEMS:-ursula s2}"
export SWEEP_RUN_ID="smoke-$(date +%s)"; export RESULTS_ROOT="results/smoke/$SWEEP_RUN_ID"; mkdir -p "$RESULTS_ROOT"
export MODE=calibrate MAX_BUMPS=0 REPEATS=1 DURATION="$DUR" FLEET_TIMEOUT=240 COORD_TIMEOUT=150
SUM="$RESULTS_ROOT/smoke.tsv"; printf 'system\tstreams\tpods\tthr_ops_s\n' > "$SUM"
echo "smoke → $RESULTS_ROOT  (streams=$STREAMS pods=$PODS dur=${DUR}s, systems=[$SYSTEMS])"

# Ensure cold-tier buckets + metrics ConfigMap.
K exec deploy/minio -- sh -c 'mc alias set local http://localhost:9000 minioadmin minioadmin >/dev/null 2>&1; mc mb -p local/ursula local/s2-bench local/durable-streams local/bench-results >/dev/null 2>&1; true' >/dev/null 2>&1 || true
ensure_metrics_configmap

run_smoke() { # name api target probe nsflag
  local name="$1" api="$2" target="$3" probe="$4" nsflag="$5"
  local n pods
  for n in ${STREAMS_LIST:-$STREAMS}; do
    pods=$(( (n + 1249) / 1250 )); [ "$pods" -lt 2 ] && pods=2   # ~1250 streams/pod, min 2 (don't client-bind)
    local cell="smoke-${name}-n${n}"
    # warmup/settle apply to ANY backend (client-side): appends during warm-up
    # warm the server, settle quiesces, only the measure window counts.
    local bench_cmd="multi-stream --target $target --api-style $api $nsflag --streams $n --duration-secs $DURATION --payload-bytes 256 --setup-concurrency 256 --warmup-secs ${WARMUP_SECS:-0} --settle-secs ${SETTLE_SECS:-0}"
    echo "── bench $name (n=$n pods=$pods warmup=${WARMUP_SECS:-0}/settle=${SETTLE_SECS:-0}/measure=$DURATION, $api → $target) ──"
    TARGET="$target" API_STYLE="$api" PROBE_HOSTPORT="$probe" INIT_PARALLELISM="$pods" MAX_PODS="$pods" \
      run_cell "$cell" "$bench_cmd" "ms" "ds-bench hdr-merge --hdr-dir /merge --results-dir /merge --label-prefix multi-stream-" 4 >&2 || true
    local cd="$RESULTS_ROOT/$cell/rep1"
    local thr; thr="$(python3 scripts/saturation.py --merged "$cd/merged.json" --prev-thr 0 --cpu 0 --cores 1 2>/dev/null | awk '{print $2}')"
    printf '%s\t%s\t%s\t%s\n' "$name" "$n" "$pods" "${thr:-FAIL}" | tee -a "$SUM"
  done
}

for sys in $SYSTEMS; do
  case "$sys" in
    ursula)
      # URSULA_WALS = WAL backends to sweep (default disk; "disk memory" compares
      # durable vs no-disk-WAL — Ursula's strict-vs-fast analog). Fresh /data each.
      for wal in ${URSULA_WALS:-disk}; do
        echo "════ deploy URSULA (wal=$wal) ════"
        K delete deploy/s2lite durable-streams ursula --ignore-not-found --wait=true >/dev/null 2>&1 || true
        SERVER_KIND=ursula PROBE_HOSTPORT="ursula:4437" URSULA_WAL="$wal" deploy_server 4 >&2 \
          || { echo "[ursula-$wal] deploy failed"; continue; }
        run_smoke "ursula-$wal" ursula http://ursula:4437 ursula:4437 "--bucket benchmark"
      done
      ;;
    s2)
      echo "════ deploy S2-LITE ════"
      K delete deploy/ursula durable-streams --ignore-not-found --wait=true >/dev/null 2>&1 || true
      K apply -f gke/s2lite.yaml >&2 || { echo "[s2] apply failed"; continue; }
      K rollout status deploy/s2lite --timeout=600s >&2 || { echo "[s2] rollout failed"; K get pods -l app=s2lite -o wide >&2; continue; }
      run_smoke s2 s2 http://s2lite:80 s2lite:80 "--basin benchmark"
      ;;
    *) echo "unknown system '$sys'";;
  esac
done

echo ""; echo "═══════ SMOKE RESULTS → $SUM ═══════"; column -t "$SUM"
echo "(cluster $CLUSTER still up)"
