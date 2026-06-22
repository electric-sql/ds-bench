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
  *) echo ""; return 1 ;; esac; }

export TARGET="http://durable-streams:4438" API_STYLE="durable" PROBE_HOSTPORT="durable-streams:4438" \
       SERVER_KIND="durable" IMG_SERVER="${IMG_SERVER:-${REG}/durable-streams:dev}"
echo "image: $IMG_SERVER"

bash scripts/cluster-up.sh > "$OUT/cluster-up.log" 2>&1 || { echo "cluster-up FAILED — see $OUT/cluster-up.log"; tail -3 "$OUT/cluster-up.log"; exit 1; }
ensure_metrics_configmap

# Fixed comfortable per-pod load; pod count = total-cardinality dial.
export DURATION="${DURATION:-20}" REPEATS=1 MS_COUNTS="$PER_POD" MF_PAIRS="" MODE=calibrate
export FLEET_TIMEOUT=480 COORD_TIMEOUT=180

for m in $MODES; do
  args="$(spec_for "$m")" || { echo "unknown mode '$m'"; continue; }
  for P in $PARS; do
    pv="${m}-P${P}"; total=$((P * PER_POD))
    echo "════ ${pv}  (total_streams=${total}, extra='${args}') ════"
    export SERVER_EXTRA_ARGS="$args"
    K delete deploy/durable-streams --ignore-not-found --wait=true >/dev/null 2>&1 || true
    # gke-scaleout reads PARALLELISM (sets its INIT_PARALLELISM from it). MAX_BUMPS=0
    # → runs at exactly P pods. P pods × PER_POD streams = total server cardinality.
    PARALLELISM="$P" MAX_PODS="$P" MAX_BUMPS=0 bash scripts/gke-scaleout.sh slow > "$OUT/$pv-scaleout.log" 2>&1
    if [ "$m" != "strict" ] && [ "$P" = "1" ]; then
      K exec deploy/durable-streams -c durable-streams -- sh -c 'cat /data/wal/shards 2>/dev/null' > "$OUT/$m-shards.txt" 2>/dev/null || true
    fi
    mkdir -p "$OUT/$pv/scaleout"
    so="$(grep -oE 'results/scaleout/[A-Za-z0-9._-]+' "$OUT/$pv-scaleout.log" | tail -1)"
    [ -n "$so" ] && [ -d "$so" ] && mv "$so" "$OUT/$pv/scaleout/"
    echo "[$pv] done (total_streams=${total}, scaleout=${so:-none})"
  done
done

echo "=== rendering ==="
python3 scripts/gen-report.py "$OUT" 2>/dev/null || echo "WARN: render failed; raw under $OUT"
echo "WAL CEILING DONE → $OUT  (per (mode×pods); cell ms-…-n${PER_POD}; total streams = pods×${PER_POD})  [teardown on exit]"
