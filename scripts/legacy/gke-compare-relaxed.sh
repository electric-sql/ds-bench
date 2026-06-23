#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# gke-compare-relaxed.sh — strict vs relaxed durability on GKE. One binary
# (durable-streams:dev, vbalegas/relaxed-durability), A/B by --durability. Each
# variant on its own cluster (parallel), matched n2d-standard-8 server node +
# cgroup budget, auto-teardown + hard-cap safety-net.
#
#   strict  = --durability strict  (== default == reference: ack after fdatasync)
#   relaxed = --durability relaxed (ack on page-cache write, no hot-path fdatasync)
#
# Validates spec SC1: relaxed ≈ the measured ref-nofsync (≈2.4× at N=10, ≈1.13× at
# N=10000; bigger at low cardinality where fsync latency is exposed). Phase 1
# (rawpower: append/reads/fan-out) + Phase 2 (scaleout cardinality sweep). Phase-2
# multi-stream/multi-fanout at PARALLELISM=1 (pod-index-less ids dedup across pods).
#
# Output: results/compare/relaxed-cpu<C>-<ts>/<impl>/{rawpower,scaleout}/ + COMPARISON.md
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PROJECT="${PROJECT:-vaxine}"
REG="europe-west1-docker.pkg.dev/${PROJECT}/ds-bench"
SERVER_CPU="${SERVER_CPU:-4}"; SERVER_MEM="${SERVER_MEM:-16Gi}"
SAFETYNET_SECS="${SAFETYNET_SECS:-9000}"   # 2.5h hard cap (2 clusters)
TS="$(date +%s)"
OUT="results/compare/relaxed-cpu${SERVER_CPU}-${TS}"
mkdir -p "$OUT"

# impl | cluster | zone
TARGETS=(
  "strict|ds-rl-str|europe-west1-d"
  "relaxed|ds-rl-rlx|europe-west1-c"
)
echo "RELAXED compare → $OUT (cpu=${SERVER_CPU}, mem=${SERVER_MEM}); 2 variants; safety-net=${SAFETYNET_SECS}s"

( sleep "$SAFETYNET_SECS"
  echo "[safety-net] hard cap reached — force-deleting all relaxed clusters" >&2
  for t in "${TARGETS[@]}"; do IFS='|' read -r _ c z <<<"$t"
    gcloud container clusters delete "$c" --zone "$z" --project "$PROJECT" --quiet 2>/dev/null
  done ) &
NETPID=$!

variant_env() {
  export SERVER_KIND=durable IMG_SERVER="${REG}/durable-streams:dev"
  export TARGET="http://durable-streams:4438" API_STYLE="durable" PROBE_HOSTPORT="durable-streams:4438"
  case "$1" in
    strict)  export SERVER_EXTRA_ARGS="--durability strict" ;;
    relaxed) export SERVER_EXTRA_ARGS="--durability relaxed" ;;
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
echo "RELAXED COMPARE DONE → $OUT/COMPARISON.md"
