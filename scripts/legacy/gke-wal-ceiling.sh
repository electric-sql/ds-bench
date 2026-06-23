#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# gke-wal-ceiling.sh — find the WAL's TRUE high-cardinality ceiling, decoupled
# from the single-client-pod limit. Each fleet pod drives a COMFORTABLE
# `--streams PER_POD` (one pod isn't the bottleneck at this size); we scale the
# POD COUNT, so total server-side streams = PER_POD × pods. This pushes the
# SERVER to high cardinality (2.5k→40k) while every client pod stays unsaturated.
#
# If the server (wal) stays flat as total cardinality grows, it's cardinality-
# robust; if throughput bends AND server CPU pegs/IO-saturates, that's its real
# limit. One cluster; pseudo-variant per (mode × pods) so gen-report tables it.
#
#   [MODES="strict wal4"] [PARS="1 2 4 8 16"] [PER_POD=2500] [ZONE=europe-west4-a] \
#     scripts/gke-wal-ceiling.sh
# Output: results/compare/wal-ceiling-<ts>/<mode>-P<pods>/scaleout/... + REPORT.md
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PROJECT="${PROJECT:-vaxine}"
REG="europe-west1-docker.pkg.dev/${PROJECT}/ds-bench"
SERVER_CPU="${SERVER_CPU:-4}"; SERVER_MEM="${SERVER_MEM:-16Gi}"
CLUSTER="${CLUSTER:-ds-wal-ceiling}"; ZONE="${ZONE:-europe-west4-a}"  # c4d-*-lssd + capacity
SAFETYNET_SECS="${SAFETYNET_SECS:-7200}"
PER_POD="${PER_POD:-2500}"
PARS="${PARS:-1 2 4 8 16}"
MODES="${MODES:-strict wal4}"
TS="$(date +%s)"
OUT="results/compare/wal-ceiling-${TS}"
mkdir -p "$OUT"

export DS_TARGET=remote PROJECT ZONE CLUSTER
export SERVER_CPUS="$SERVER_CPU" SERVER_MEM
export LOCAL_SSD_COUNT="${LOCAL_SSD_COUNT:-1}" CLIENT_NODES="${CLIENT_NODES:-4}"  # headroom for up to 16 fleet pods
# shellcheck source=scripts/lib-bench.sh
. scripts/lib-bench.sh

echo "WAL ceiling → $OUT (cluster=$CLUSTER@$ZONE, cpu=$SERVER_CPU); modes=[$MODES] pars=[$PARS] per_pod=$PER_POD"

( sleep "$SAFETYNET_SECS"; echo "[safety-net] hard cap — force-deleting $CLUSTER" >&2
  gcloud container clusters delete "$CLUSTER" --zone "$ZONE" --project "$PROJECT" --quiet 2>/dev/null ) &
NETPID=$!
trap 'echo "[teardown] deleting $CLUSTER"; DS_TARGET=remote PROJECT="$PROJECT" CLUSTER="$CLUSTER" ZONE="$ZONE" bash scripts/cluster-down.sh >/dev/null 2>&1; kill "$NETPID" 2>/dev/null' EXIT INT TERM

spec_for() { case "$1" in
  strict) echo "--durability strict" ;;
  fast)   echo "--durability fast" ;;
  wal4)   echo "--durability wal --wal-shards 4" ;;
  wal16)  echo "--durability wal --wal-shards 16" ;;
  wal32)  echo "--durability wal --wal-shards 32" ;;
  wal64)  echo "--durability wal --wal-shards 64" ;;
  *) echo ""; return 1 ;; esac; }

export TARGET="http://durable-streams:4438" API_STYLE="durable" PROBE_HOSTPORT="durable-streams:4438" \
       SERVER_KIND="durable" IMG_SERVER="${IMG_SERVER:-${REG}/durable-streams:dev}"
echo "image: $IMG_SERVER"

bash scripts/cluster-up.sh > "$OUT/cluster-up.log" 2>&1 || { echo "cluster-up FAILED — see $OUT/cluster-up.log"; tail -3 "$OUT/cluster-up.log"; exit 1; }
ensure_metrics_configmap

# Two modes:
#  default   — fixed PER_POD load, PARS = pod counts → total = pods × PER_POD.
#  FIXED_PODS — fixed pod count, PARS = TOTAL stream counts → per_pod = total / FIXED_PODS.
#               (decouples client fan-out from server cardinality: feed the SAME
#                server cardinality with many light pods to isolate client vs server.)
export DURATION="${DURATION:-20}" REPEATS=1 MF_PAIRS="" MODE=calibrate
export FLEET_TIMEOUT=480 COORD_TIMEOUT=180

# Build cell specs "PODS:PERPOD:TOTAL".
#   CELLS="P@T P@T …"  — explicit (pods @ total); the fan-out-at-fixed-load knob.
#   FIXED_PODS + PARS  — PARS are TOTALS at a fixed pod count.
#   else PARS + PER_POD — PARS are pod counts × fixed PER_POD.
CELL_SPECS=""
if [ -n "${CELLS:-}" ]; then
  for c in $CELLS; do p="${c%@*}"; t="${c#*@}"; CELL_SPECS="$CELL_SPECS ${p}:$(( t / p )):${t}"; done
elif [ -n "${FIXED_PODS:-}" ]; then
  for x in $PARS; do CELL_SPECS="$CELL_SPECS ${FIXED_PODS}:$(( x / FIXED_PODS )):${x}"; done
else
  for x in $PARS; do CELL_SPECS="$CELL_SPECS ${x}:${PER_POD}:$(( x * PER_POD ))"; done
fi
echo "cells (pods:perpod:total): $CELL_SPECS"

for m in $MODES; do
  args="$(spec_for "$m")" || { echo "unknown mode '$m'"; continue; }
  for spec in $CELL_SPECS; do
    P="${spec%%:*}"; perpod="${spec#*:}"; perpod="${perpod%%:*}"; total="${spec##*:}"
    pv="${m}-N${total}-P${P}"
    echo "════ ${pv}  (total_streams=${total}, pods=${P}, per_pod=${perpod}, extra='${args}') ════"
    export SERVER_EXTRA_ARGS="$args"
    K delete deploy/durable-streams --ignore-not-found --wait=true >/dev/null 2>&1 || true
    # MAX_BUMPS=0 → runs at exactly P pods; MS_COUNTS=perpod → per-pod stream count.
    PARALLELISM="$P" MAX_PODS="$P" MAX_BUMPS=0 MS_COUNTS="$perpod" bash scripts/gke-scaleout.sh slow > "$OUT/$pv-scaleout.log" 2>&1
    if [ "$m" != "strict" ] && [ "$P" = "1" ]; then
      K exec deploy/durable-streams -c durable-streams -- sh -c 'cat /data/wal/shards 2>/dev/null' > "$OUT/$m-shards.txt" 2>/dev/null || true
    fi
    # fd diagnostics — confirm/deny the fd-ceiling hypothesis at high cardinality.
    K exec deploy/durable-streams -c durable-streams -- sh -c \
      'echo "$(grep "Max open files" /proc/1/limits) | open_fds=$(ls /proc/1/fd 2>/dev/null | wc -l)"' \
      > "$OUT/$pv-fd.txt" 2>/dev/null || true
    K logs deploy/durable-streams -c durable-streams --tail=3000 2>/dev/null \
      | grep -iE "too many open|emfile|os error 24|os error 99|accept|connection reset|refused" \
      | sort | uniq -c | sort -rn | head -8 > "$OUT/$pv-srverr.txt" 2>/dev/null || true
    echo "[$pv] fd: $(cat "$OUT/$pv-fd.txt" 2>/dev/null)"
    mkdir -p "$OUT/$pv/scaleout"
    so="$(grep -oE 'results/scaleout/[A-Za-z0-9._-]+' "$OUT/$pv-scaleout.log" | tail -1)"
    [ -n "$so" ] && [ -d "$so" ] && mv "$so" "$OUT/$pv/scaleout/"
    echo "[$pv] done (total_streams=${total}, scaleout=${so:-none})"
  done
done

echo "=== rendering ==="
python3 scripts/gen-report.py "$OUT" 2>/dev/null || echo "WARN: render failed; raw under $OUT"
echo "WAL CEILING DONE → $OUT  (per (mode×pods); cell ms-…-n${PER_POD}; total streams = pods×${PER_POD})  [teardown on exit]"
