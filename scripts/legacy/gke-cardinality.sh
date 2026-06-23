#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# gke-cardinality.sh — FAST cardinality sweep on a PERSISTENT cluster.
#
# Deploys the server ONCE per durability mode (fresh /data), then runs a whole
# cardinality ladder against it — NO per-cell redeploy (the ~1.5min/cell killer).
# Assumes the cluster is ALREADY UP (scripts/cluster-up.sh) and does NOT create
# or tear it down, so re-runs / tweaks are just the cells. Pair with a low
# FLEET_CPU + sized CLIENT_NODES for high pod fan-out.
#
#   CELLS="N@pods ..."   N = TOTAL streams, pods = fleet pods (per-pod=ceil(N/pods))
#   MODES="strict fast wal4 wal16 wal64"
#
#   PROJECT=vaxine ZONE=europe-west4-a CLUSTER=ds-bench-persist FLEET_CPU=0.5 \
#     CELLS="1@1 10@1 100@1 1000@2 10000@16 50000@64 100000@64 100000@128" \
#     MODES="strict fast wal4 wal16 wal64" DURATION=15 scripts/gke-cardinality.sh
#
# Output: results/cardinality/card-<ts>/summary.tsv (+ per-cell merged/samples).
# TEARDOWN IS SEPARATE — the cluster stays up. Delete it when done.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$(pwd)"; export REPO_ROOT   # lib-bench references ${REPO_ROOT} for saturation.py/pins.py
export DS_TARGET="${DS_TARGET:-remote}"
export PROJECT="${PROJECT:-vaxine}" ZONE="${ZONE:?set ZONE}" CLUSTER="${CLUSTER:?set CLUSTER}"
export SERVER_CPUS="${SERVER_CPUS:-4}" SERVER_MEM="${SERVER_MEM:-16Gi}"
# shellcheck source=scripts/lib-bench.sh
. scripts/lib-bench.sh

SERVER_CPU="${SERVER_CPUS%% *}"
CELLS="${CELLS:-1@1 10@1 100@1 1000@2 10000@16 50000@64 100000@64 100000@128}"
MODES="${MODES:-strict fast wal4 wal16 wal64}"
export DURATION="${DURATION:-15}" REPEATS=1 MODE=calibrate MAX_BUMPS=0
export FLEET_TIMEOUT="${FLEET_TIMEOUT:-300}" COORD_TIMEOUT="${COORD_TIMEOUT:-150}"
export TARGET="http://durable-streams:4438" API_STYLE=durable \
       PROBE_HOSTPORT="durable-streams:4438" SERVER_KIND=durable

TS="$(date +%s)"
export SWEEP_RUN_ID="card-${TS}"
export RESULTS_ROOT="results/cardinality/card-${TS}"
mkdir -p "$RESULTS_ROOT"
SUM="$RESULTS_ROOT/summary.tsv"
printf 'mode\tN\tpods\tperpod\tthr_ops_s\tcpu_pct\n' > "$SUM"

spec_for() { case "$1" in
  strict) echo "--durability strict" ;;
  fast)   echo "--durability fast" ;;
  wal1)   echo "--durability wal --wal-shards 1" ;;
  wal4)   echo "--durability wal --wal-shards 4" ;;
  wal16)  echo "--durability wal --wal-shards 16" ;;
  wal64)  echo "--durability wal --wal-shards 64" ;;
  *) return 1 ;; esac; }

echo "cardinality sweep → $RESULTS_ROOT  (cluster=$CLUSTER@$ZONE, fleet_cpu=${FLEET_CPU}, dur=${DURATION}s)"
echo "cells: $CELLS"
echo "modes: $MODES"
ensure_metrics_configmap

# FRESH_PER_CELL=1 → redeploy a clean server (empty /data) before EVERY cell, so
# the measured cardinality is the ONLY resident stream count (no accumulation
# across cells). Default (unset) = deploy once per mode (fast, but accumulates).
for m in $MODES; do
  args="$(spec_for "$m")" || { echo "skip unknown mode '$m'"; continue; }
  export SERVER_EXTRA_ARGS="$args"
  if [ -z "${FRESH_PER_CELL:-}" ]; then
    echo "════════════ MODE $m  ($args) — deploy once ════════════"
    K delete deploy/durable-streams --ignore-not-found --wait=true >/dev/null 2>&1 || true
    deploy_server "$SERVER_CPU" >&2 || { echo "[$m] deploy failed — skipping mode"; continue; }
  else
    echo "════════════ MODE $m  ($args) — FRESH server per cell ════════════"
  fi
  for cell_spec in $CELLS; do
    N="${cell_spec%@*}"; pods="${cell_spec#*@}"
    perpod=$(( (N + pods - 1) / pods ))   # ceil(N/pods)
    cell="${m}-N${N}-P${pods}"
    if [ -n "${FRESH_PER_CELL:-}" ]; then
      K delete deploy/durable-streams --ignore-not-found --wait=true >/dev/null 2>&1 || true
      deploy_server "$SERVER_CPU" >&2 || { echo "[$cell] deploy failed — skipping cell"; continue; }
    fi
    bench_cmd="multi-stream --target ${TARGET} --api-style ${API_STYLE} --streams ${perpod} --duration-secs ${DURATION} --payload-bytes 256 --warmup-secs ${WARMUP_SECS:-0} --settle-secs ${SETTLE_SECS:-0}"
    echo "── cell $cell  (N=$N pods=$pods perpod=$perpod) ──"
    INIT_PARALLELISM="$pods" MAX_PODS="$pods" \
      run_cell "$cell" "$bench_cmd" "ms" "ds-bench hdr-merge --hdr-dir /merge --results-dir /merge --label-prefix multi-stream-" "$SERVER_CPU" >&2 || true
    cd_dir="$RESULTS_ROOT/$cell/rep1"
    cpu="$(compute_server_cpu_pct "$cd_dir/samples.csv" 2>/dev/null || echo 0)"
    thr="$(python3 scripts/saturation.py --merged "$cd_dir/merged.json" --prev-thr 0 --cpu "$cpu" --cores 1 2>/dev/null | awk '{print $2}')"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$m" "$N" "$pods" "$perpod" "${thr:-0}" "${cpu:-0}" | tee -a "$SUM"
  done
done

echo ""; echo "═══════════ DONE → $SUM ═══════════"
column -t "$SUM" 2>/dev/null || cat "$SUM"
echo "(cluster $CLUSTER STILL UP — tear down when finished)"
