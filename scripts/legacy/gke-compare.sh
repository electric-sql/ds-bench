#!/usr/bin/env bash
# gke-compare.sh — run phases 1+2 for multiple durable-streams server implementations
# on GKE at a FIXED server size, each on its own cluster (parallel), then render a
# side-by-side comparison. Every implementation sees identical client load + server
# budget, so the diff is purely the server.
#
#   IMPLS="reference=<img> io-uring=<img>"  scripts/gke-compare.sh
#
# Each cluster is torn down on exit (trap) and a global safety-net force-deletes any
# survivors. Results: results/compare/gke-cpu<C>-mem<M>-<ts>/<impl>/<phase>/... + COMPARISON.md
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

REG="europe-west1-docker.pkg.dev/${PROJECT:-vaxine}/ds-bench"
SERVER_CPU="${SERVER_CPU:-4}"
SERVER_MEM="${SERVER_MEM:-16Gi}"
TS="$(date +%s)"
OUT="results/compare/gke-cpu${SERVER_CPU}-mem${SERVER_MEM%Gi}-${TS}"
mkdir -p "$OUT"
# impl=cluster=zone tuples (distinct zones in the same benchmarking subnet)
TARGETS=(
  "reference|${REG}/durable-streams-reference:dev|ds-cmp-ref|europe-west1-d"
  "io-uring|${REG}/durable-streams-iouring:dev|ds-cmp-iou|europe-west1-c"
)
echo "compare → $OUT  (cpu=${SERVER_CPU}, mem=${SERVER_MEM})"

# Global safety-net: force-delete both clusters after 90min if anything wedges.
( sleep 5400
  for t in "${TARGETS[@]}"; do IFS='|' read -r _ _ c z <<<"$t"
    gcloud container clusters delete "$c" --zone "$z" --project "${PROJECT:-vaxine}" --quiet 2>/dev/null
  done ) &
NETPID=$!

run_impl() {
  local impl="$1" img="$2" cluster="$3" zone="$4"
  ( trap "DS_TARGET=remote PROJECT=${PROJECT:-vaxine} CLUSTER=$cluster ZONE=$zone bash scripts/cluster-down.sh >/dev/null 2>&1" EXIT
    set -e
    export DS_TARGET=remote PROJECT="${PROJECT:-vaxine}" ZONE="$zone" CLUSTER="$cluster" IMG_SERVER="$img"
    export SERVER_CPUS="$SERVER_CPU" SERVER_MEM="$SERVER_MEM"
    export LOCAL_SSD_COUNT="${LOCAL_SSD_COUNT:-1}" CLIENT_NODES="${CLIENT_NODES:-4}"
    export PARALLELISM=4 MAX_BUMPS="${MAX_BUMPS:-4}" MAX_PODS="${MAX_PODS:-24}" REPEATS="${REPEATS:-1}"
    export FLEET_TIMEOUT=300 COORD_TIMEOUT=120
    # phase 1 (rawpower) cells — fixed single cell each, bytes-only, no splice/cold
    export READ_SIZES="1024" READ_CONNS="256" APPEND_PAYLOADS="1024" APPEND_CONNS="256" \
           FO_SUBS_LIST="256" SKIP_SPLICE=1 SKIP_COLD=1
    # phase 2 (scaleout) cells
    export MS_COUNTS="10 100" MF_PAIRS="10:10"
    echo "[$impl] cluster-up ($cluster@$zone)"
    bash scripts/cluster-up.sh   > "$OUT/$impl-up.log"       2>&1
    echo "[$impl] phase 1 rawpower"
    bash scripts/gke-rawpower.sh slow > "$OUT/$impl-rawpower.log" 2>&1
    echo "[$impl] phase 2 scaleout"
    bash scripts/gke-scaleout.sh slow > "$OUT/$impl-scaleout.log" 2>&1
    mkdir -p "$OUT/$impl/rawpower" "$OUT/$impl/scaleout"
    rp="$(grep -oE 'results/rawpower/[A-Za-z0-9._-]+' "$OUT/$impl-rawpower.log" | tail -1)"
    so="$(grep -oE 'results/scaleout/[A-Za-z0-9._-]+' "$OUT/$impl-scaleout.log" | tail -1)"
    [ -n "$rp" ] && [ -d "$rp" ] && mv "$rp" "$OUT/$impl/rawpower/"
    [ -n "$so" ] && [ -d "$so" ] && mv "$so" "$OUT/$impl/scaleout/"
    echo "[$impl] teardown"
  )
  echo "[$impl] finished (rc=$?)"
}

pids=()
for t in "${TARGETS[@]}"; do
  IFS='|' read -r impl img cluster zone <<<"$t"
  run_impl "$impl" "$img" "$cluster" "$zone" &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done

echo "=== rendering comparison ==="
python3 scripts/compare-impls.py "$OUT"
kill "$NETPID" 2>/dev/null
echo "GKE COMPARE DONE → $OUT/COMPARISON.md"
