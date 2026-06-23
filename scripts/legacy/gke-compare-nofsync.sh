#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# gke-compare-nofsync.sh — isolate the fsync cost. 3 variants, 1 binary
# (durable-streams:dev, WAL branch + --no-fsync), each on its own cluster (parallel),
# matched n2d-standard-8 server node + cgroup budget, auto-teardown + hard-cap net.
#
#   reference         = --wal off, fsync ON   (durable baseline)
#   ref-nofsync       = --wal off, --no-fsync  (NON-DURABLE ceiling — "disable fsync, no WAL")
#   wal-async-nofsync = --wal --wal-sync async --no-fsync  (is the WAL salvageable when
#                        fsync is free? if it still collapses, the materializer write-path
#                        — not fsync — is the wall)
#
# Decisive question: if ref-nofsync ≈ reference, parallel per-stream fsync is already cheap
# and the WAL buys nothing; if ref-nofsync ≫ reference, fsync is the real cost.
#
# Suite = Phase 1 (rawpower) + Phase 2 (scaleout cardinality sweep). Phase-2
# multi-stream/multi-fanout at PARALLELISM=1 (pod-index-less ids dedup across pods).
#
# Output: results/compare/nofsync-cpu<C>-<ts>/<impl>/{rawpower,scaleout}/ + COMPARISON.md
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PROJECT="${PROJECT:-vaxine}"
REG="europe-west1-docker.pkg.dev/${PROJECT}/ds-bench"
SERVER_CPU="${SERVER_CPU:-4}"; SERVER_MEM="${SERVER_MEM:-16Gi}"
SAFETYNET_SECS="${SAFETYNET_SECS:-10800}"   # 3h hard cap
TS="$(date +%s)"
OUT="results/compare/nofsync-cpu${SERVER_CPU}-${TS}"
mkdir -p "$OUT"

# impl | cluster | zone
TARGETS=(
  "reference|ds-nf-ref|europe-west1-d"
  "ref-nofsync|ds-nf-rnf|europe-west1-c"
  "wal-async-nofsync|ds-nf-wan|europe-west1-b"
)
echo "NOFSYNC compare → $OUT (cpu=${SERVER_CPU}, mem=${SERVER_MEM}); 3 variants; safety-net=${SAFETYNET_SECS}s"

( sleep "$SAFETYNET_SECS"
  echo "[safety-net] hard cap reached — force-deleting all nofsync clusters" >&2
  for t in "${TARGETS[@]}"; do IFS='|' read -r _ c z <<<"$t"
    gcloud container clusters delete "$c" --zone "$z" --project "$PROJECT" --quiet 2>/dev/null
  done ) &
NETPID=$!

variant_env() {
  export SERVER_KIND=durable IMG_SERVER="${REG}/durable-streams:dev"
  export TARGET="http://durable-streams:4438" API_STYLE="durable" PROBE_HOSTPORT="durable-streams:4438"
  case "$1" in
    reference)         export SERVER_EXTRA_ARGS="" ;;
    ref-nofsync)       export SERVER_EXTRA_ARGS="--no-fsync" ;;
    wal-async-nofsync) export SERVER_EXTRA_ARGS="--wal --wal-sync async --no-fsync" ;;
  esac
}

run_impl() {
  local impl="$1" cluster="$2" zone="$3"
  ( trap "DS_TARGET=remote PROJECT=${PROJECT} CLUSTER=$cluster ZONE=$zone bash scripts/cluster-down.sh >/dev/null 2>&1" EXIT
    set -e
    export DS_TARGET=remote PROJECT="$PROJECT" ZONE="$zone" CLUSTER="$cluster"
    export SERVER_CPUS="$SERVER_CPU" SERVER_MEM="$SERVER_MEM"
    export LOCAL_SSD_COUNT="${LOCAL_SSD_COUNT:-1}" CLIENT_NODES="${CLIENT_NODES:-4}"
    export FLEET_TIMEOUT=360 COORD_TIMEOUT=120 DURATION="${DURATION:-25}" REPEATS="${REPEATS:-1}"
    variant_env "$impl"
    export READ_SIZES="1024" READ_CONNS="256" APPEND_PAYLOADS="1024" APPEND_CONNS="256" \
           FO_SUBS_LIST="1 10 100" SKIP_SPLICE=1 SKIP_COLD=1
    export MS_COUNTS="10 100 1000 10000" MF_PAIRS="10:10"

    echo "[$impl] cluster-up ($cluster@$zone)"
    bash scripts/cluster-up.sh > "$OUT/$impl-up.log" 2>&1
    echo "[$impl] phase 1 rawpower"
    PARALLELISM=4 MAX_PODS=24 MAX_BUMPS=3 \
      bash scripts/gke-rawpower.sh slow > "$OUT/$impl-rawpower.log" 2>&1
    echo "[$impl] phase 2 scaleout (cardinality sweep)"
    PARALLELISM=1 MAX_PODS=1 MAX_BUMPS=0 \
      bash scripts/gke-scaleout.sh slow > "$OUT/$impl-scaleout.log" 2>&1

    mkdir -p "$OUT/$impl/rawpower" "$OUT/$impl/scaleout"
    if [ "$impl" = "wal-async-nofsync" ]; then
      kubectl --context "gke_${PROJECT}_${zone}_${cluster}" -n ds-bench \
        logs deploy/durable-streams -c durable-streams --tail=800 2>/dev/null \
        | grep WAL_STATS | tail -20 > "$OUT/$impl/wal_stats.txt" || true
    fi
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
  IFS='|' read -r impl cluster zone <<<"$t"
  run_impl "$impl" "$cluster" "$zone" &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done

echo "=== rendering comparison ==="
python3 scripts/compare-impls.py "$OUT" || echo "WARN: compare-impls.py failed (data under $OUT)"
kill "$NETPID" 2>/dev/null
echo "NOFSYNC COMPARE DONE → $OUT/COMPARISON.md"
