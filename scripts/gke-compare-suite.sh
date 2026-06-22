#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# gke-compare-suite.sh — 3-way COMPLETE-SUITE comparison on GKE, fixed server size,
# each variant on its own cluster (parallel), auto-teardown + hard-cap safety-net.
#
#   reference  = durable-streams, --wal off          (per-stream group-commit)
#   wal-strict = durable-streams, --wal --wal-sync strict (shared-WAL group commit)
#   ursula     = ursula single-node (Raft disk WAL), --api-style ursula
#
# reference + wal-strict share ONE image (durable-streams:dev, WAL branch; A/B by
# flag). All three get the SAME node (role=server n2d-standard-8) and the SAME
# cgroup budget (SERVER_CPU / SERVER_MEM) — a fair, server-only diff.
#
# Suite = Phase 1 (rawpower: append/reads/fan-out) + Phase 2 (scaleout: multi-stream
# cardinality sweep N=10..10000 + multi-fanout). Phase-2 multi-stream/multi-fanout
# run at PARALLELISM=1 (their stream/producer ids don't include the pod index, so
# >1 pod dedups — one pod with one writer-task-per-stream is the correct load).
#
# CAVEAT: ursula is built for multi-node; single-node here is the agreed baseline
# (multi-node deferred). Splice/cold-tier cells are durable-only → skipped.
#
# Output: results/compare/suite-cpu<C>-<ts>/<impl>/{rawpower,scaleout}/ + COMPARISON.md
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PROJECT="${PROJECT:-vaxine}"
REG="europe-west1-docker.pkg.dev/${PROJECT}/ds-bench"
SERVER_CPU="${SERVER_CPU:-4}"; SERVER_MEM="${SERVER_MEM:-16Gi}"
# Hard upper bound: force-delete every cluster after this many seconds no matter
# what wedges (the user's standing requirement). Monitoring tears down sooner.
SAFETYNET_SECS="${SAFETYNET_SECS:-10800}"   # 3h
TS="$(date +%s)"
OUT="results/compare/suite-cpu${SERVER_CPU}-${TS}"
mkdir -p "$OUT"

# impl | cluster | zone
TARGETS=(
  "reference|ds-suite-ref|europe-west1-d"
  "wal-strict|ds-suite-wal|europe-west1-c"
  "ursula|ds-suite-urs|europe-west1-b"
)
echo "SUITE compare → $OUT (cpu=${SERVER_CPU}, mem=${SERVER_MEM}); 3 variants; safety-net=${SAFETYNET_SECS}s"

# ── global hard-cap safety-net: force-delete all clusters after SAFETYNET_SECS ──
( sleep "$SAFETYNET_SECS"
  echo "[safety-net] hard cap reached — force-deleting all suite clusters" >&2
  for t in "${TARGETS[@]}"; do IFS='|' read -r _ c z <<<"$t"
    gcloud container clusters delete "$c" --zone "$z" --project "$PROJECT" --quiet 2>/dev/null
  done ) &
NETPID=$!

# Per-variant environment (server kind/args/image + bench target/api/probe).
variant_env() {
  case "$1" in
    reference)
      export SERVER_KIND=durable SERVER_EXTRA_ARGS="" IMG_SERVER="${REG}/durable-streams:dev"
      export TARGET="http://durable-streams:4438" API_STYLE="durable" PROBE_HOSTPORT="durable-streams:4438" ;;
    wal-strict)
      export SERVER_KIND=durable SERVER_EXTRA_ARGS="--wal --wal-sync strict" IMG_SERVER="${REG}/durable-streams:dev"
      export TARGET="http://durable-streams:4438" API_STYLE="durable" PROBE_HOSTPORT="durable-streams:4438" ;;
    ursula)
      export SERVER_KIND=ursula SERVER_EXTRA_ARGS="" IMG_URSULA="${REG}/ursula:dev"
      export TARGET="http://ursula:4437" API_STYLE="ursula" PROBE_HOSTPORT="ursula:4437" ;;
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

    # Phase-1 dims (lean, comparable across all three; splice/cold are durable-only).
    export READ_SIZES="1024" READ_CONNS="256" APPEND_PAYLOADS="1024" APPEND_CONNS="256" \
           FO_SUBS_LIST="1 10 100" SKIP_SPLICE=1 SKIP_COLD=1
    # Phase-2 cardinality sweep.
    export MS_COUNTS="10 100 1000 10000" MF_PAIRS="10:10"

    echo "[$impl] cluster-up ($cluster@$zone)"
    bash scripts/cluster-up.sh > "$OUT/$impl-up.log" 2>&1

    # Phase 1: append/reads/fan-out shard correctly across pods → headroom-bump.
    echo "[$impl] phase 1 rawpower"
    PARALLELISM=4 MAX_PODS=24 MAX_BUMPS=3 \
      bash scripts/gke-rawpower.sh slow > "$OUT/$impl-rawpower.log" 2>&1

    # Phase 2: multi-stream/multi-fanout dedup across pods → single pod, no bump.
    echo "[$impl] phase 2 scaleout (cardinality sweep)"
    PARALLELISM=1 MAX_PODS=1 MAX_BUMPS=0 \
      bash scripts/gke-scaleout.sh slow > "$OUT/$impl-scaleout.log" 2>&1

    mkdir -p "$OUT/$impl/rawpower" "$OUT/$impl/scaleout"
    # WAL telemetry snapshot (steady state of the last/10k cell) — before teardown.
    if [ "$impl" = "wal-strict" ]; then
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
python3 scripts/compare-impls.py "$OUT" || echo "WARN: compare-impls.py failed (data still under $OUT)"
kill "$NETPID" 2>/dev/null
echo "SUITE COMPARE DONE → $OUT/COMPARISON.md"
