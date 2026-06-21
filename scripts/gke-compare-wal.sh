#!/usr/bin/env bash
# gke-compare-wal.sh — 3-way comparison: reference vs WAL-strict (durable group commit)
# vs WAL-async (relaxed). Centered on the multi-stream cardinality sweep (the wall) +
# single-stream append. Each variant on its own cluster (parallel), fixed server size,
# auto-teardown. Output: results/compare/wal-cpu<C>-<ts>/<impl>/... + COMPARISON.md
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REG="europe-west1-docker.pkg.dev/${PROJECT:-vaxine}/ds-bench"
SERVER_CPU="${SERVER_CPU:-4}"; SERVER_MEM="${SERVER_MEM:-16Gi}"
TS="$(date +%s)"
OUT="results/compare/wal-cpu${SERVER_CPU}-${TS}"
mkdir -p "$OUT"
# impl | image | extra server args | cluster | zone
TARGETS=(
  "reference|${REG}/durable-streams-reference:dev||ds-wal-ref|europe-west1-d"
  "wal-strict|${REG}/durable-streams-wal:dev|--wal --wal-sync strict --wal-fsync-events 1|ds-wal-str|europe-west1-c"
  "wal-async|${REG}/durable-streams-wal:dev|--wal --wal-sync async --wal-fsync-events 256|ds-wal-asy|europe-west1-b"
)
echo "WAL compare → $OUT (cpu=${SERVER_CPU}, mem=${SERVER_MEM}); 3 variants"

# Global safety-net: force-delete all clusters after 110min if anything wedges.
( sleep 6600
  for t in "${TARGETS[@]}"; do IFS='|' read -r _ _ _ c z <<<"$t"
    gcloud container clusters delete "$c" --zone "$z" --project "${PROJECT:-vaxine}" --quiet 2>/dev/null
  done ) &
NETPID=$!

run_impl() {
  local impl="$1" img="$2" xargs_="$3" cluster="$4" zone="$5"
  ( trap "DS_TARGET=remote PROJECT=${PROJECT:-vaxine} CLUSTER=$cluster ZONE=$zone bash scripts/cluster-down.sh >/dev/null 2>&1" EXIT
    set -e
    export DS_TARGET=remote PROJECT="${PROJECT:-vaxine}" ZONE="$zone" CLUSTER="$cluster" IMG_SERVER="$img"
    export SERVER_EXTRA_ARGS="$xargs_"          # injected into every deploy_server (incl --wal)
    export SERVER_CPUS="$SERVER_CPU" SERVER_MEM="$SERVER_MEM"
    export LOCAL_SSD_COUNT="${LOCAL_SSD_COUNT:-1}" CLIENT_NODES="${CLIENT_NODES:-4}"
    export PARALLELISM=4 MAX_BUMPS="${MAX_BUMPS:-4}" MAX_PODS="${MAX_PODS:-24}" REPEATS="${REPEATS:-1}"
    export FLEET_TIMEOUT=300 COORD_TIMEOUT=120 DURATION="${DURATION:-25}"
    # phase 1 (rawpower): single-stream append + reads (write/read baseline) — bytes only
    export READ_SIZES="1024" READ_CONNS="256" APPEND_PAYLOADS="1024" APPEND_CONNS="256" \
           FO_SUBS_LIST="256" SKIP_SPLICE=1 SKIP_COLD=1
    # phase 2 (scaleout): the CARDINALITY SWEEP — the headline test for the WAL
    export MS_COUNTS="10 100 1000 10000" MF_PAIRS="10:10"
    echo "[$impl] cluster-up ($cluster@$zone) extra='${xargs_:-none}'"
    bash scripts/cluster-up.sh        > "$OUT/$impl-up.log"       2>&1
    echo "[$impl] phase 1 rawpower"
    bash scripts/gke-rawpower.sh slow > "$OUT/$impl-rawpower.log" 2>&1
    echo "[$impl] phase 2 scaleout (cardinality sweep)"
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
  IFS='|' read -r impl img xargs_ cluster zone <<<"$t"
  run_impl "$impl" "$img" "$xargs_" "$cluster" "$zone" &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done

echo "=== rendering comparison ==="
python3 scripts/compare-impls.py "$OUT"
kill "$NETPID" 2>/dev/null
echo "WAL COMPARE DONE → $OUT/COMPARISON.md"
