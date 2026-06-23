#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# gke-wal-shardsweep.sh — confirm the WAL high-cardinality cliff is a
# FSYNC-PARALLELISM FUNNEL (not the watch/wakeup): on ONE cluster, sweep
# `--wal-shards {4,16,64}` + a `strict` baseline, run the scaleout cardinality
# cells at a FIXED 1 pod (matched load — the trustworthy par=1 methodology),
# and CAPTURE the server boot log + persisted shard count per variant (closing
# the "couldn't verify shard count" gap). Auto-teardown + hard-cap safety-net.
#
# Hypothesis: wal_throughput ≈ N_shards × per_committer_rate. If wal's cap rises
# from ~35k (4 shards) toward strict's ~97k as shards grow — at a FIXED 4-CPU
# budget — the funnel is confirmed and the bottleneck is fsync parallelism, not
# CPU. (Run AFTER the spawn_blocking-committer image is built, so >4 committers
# actually fsync concurrently on the blocking pool.)
#
#   [VARIANTS="strict wal4 wal16 wal64"] [SERVER_CPU=4] [MS_COUNTS="100 1000 10000"] \
#     scripts/gke-wal-shardsweep.sh
# Output: results/compare/wal-shardsweep-<ts>/<variant>/scaleout/... + bootlog/shards
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PROJECT="${PROJECT:-vaxine}"
REG="europe-west1-docker.pkg.dev/${PROJECT}/ds-bench"
SERVER_CPU="${SERVER_CPU:-4}"; SERVER_MEM="${SERVER_MEM:-16Gi}"
CLUSTER="${CLUSTER:-ds-wal-shardsweep}"; ZONE="${ZONE:-europe-west1-b}"  # c4d-*-lssd offered here (same region as the AR registry)
SAFETYNET_SECS="${SAFETYNET_SECS:-7200}"   # 2h hard cap (force-delete if anything wedges)
VARIANTS="${VARIANTS:-strict wal4 wal16 wal64}"
TS="$(date +%s)"
OUT="results/compare/wal-shardsweep-${TS}"
mkdir -p "$OUT"

export DS_TARGET=remote PROJECT ZONE CLUSTER
export SERVER_CPUS="$SERVER_CPU" SERVER_MEM
export LOCAL_SSD_COUNT="${LOCAL_SSD_COUNT:-1}" CLIENT_NODES="${CLIENT_NODES:-2}"
# shellcheck source=scripts/lib-bench.sh
. scripts/lib-bench.sh   # K() + KCTX + deploy_server + ensure_metrics_configmap

echo "WAL shard-sweep → $OUT (cluster=$CLUSTER@$ZONE, cpu=$SERVER_CPU, mem=$SERVER_MEM); variants=[$VARIANTS]"

# ── hard-cap safety-net + guaranteed single-cluster teardown on exit ──────────
( sleep "$SAFETYNET_SECS"
  echo "[safety-net] hard cap reached — force-deleting $CLUSTER" >&2
  gcloud container clusters delete "$CLUSTER" --zone "$ZONE" --project "$PROJECT" --quiet 2>/dev/null ) &
NETPID=$!
trap 'echo "[teardown] deleting $CLUSTER"; DS_TARGET=remote PROJECT="$PROJECT" CLUSTER="$CLUSTER" ZONE="$ZONE" bash scripts/cluster-down.sh >/dev/null 2>&1; kill "$NETPID" 2>/dev/null' EXIT INT TERM

spec_for() {
  case "$1" in
    strict) echo "--durability strict" ;;
    wal4)   echo "--durability wal --wal-shards 4" ;;
    wal16)  echo "--durability wal --wal-shards 16" ;;
    wal64)  echo "--durability wal --wal-shards 64" ;;
    wal128) echo "--durability wal --wal-shards 128" ;;
    *) echo ""; return 1 ;;
  esac
}

export TARGET="http://durable-streams:4438" API_STYLE="durable" PROBE_HOSTPORT="durable-streams:4438" \
       SERVER_KIND="durable" IMG_SERVER="${IMG_SERVER:-${REG}/durable-streams:dev}"
echo "image: $IMG_SERVER"

bash scripts/cluster-up.sh > "$OUT/cluster-up.log" 2>&1 || { echo "cluster-up FAILED — see $OUT/cluster-up.log"; exit 1; }
ensure_metrics_configmap

# Matched cell matrix for every variant: cardinality sweep at a FIXED 1 pod.
export FLEET_TIMEOUT=360 COORD_TIMEOUT=120 DURATION="${DURATION:-20}" REPEATS=1
export MS_COUNTS="${MS_COUNTS:-100 1000 10000}" MF_PAIRS="10:10"
export MODE=calibrate   # with MAX_BUMPS=0 this pins at 1 pod and runs (no bump loop)

for v in $VARIANTS; do
  args="$(spec_for "$v")" || { echo "unknown variant '$v' — skipping"; continue; }
  echo "════════════════════════════════════════════════════════════════════"
  echo "=== variant: $v  (extra='${args}') ==="
  echo "════════════════════════════════════════════════════════════════════"
  export SERVER_EXTRA_ARGS="$args"
  # Clean slate: fresh /data emptyDir for the next variant.
  K delete deploy/durable-streams --ignore-not-found --wait=true >/dev/null 2>&1 || true
  deploy_server "$SERVER_CPU" > "$OUT/$v-deploy.log" 2>&1 || { echo "[$v] deploy failed"; tail -5 "$OUT/$v-deploy.log"; continue; }
  # CAPTURE boot log + persisted shard count (the gap the last run had).
  K logs deploy/durable-streams -c durable-streams --tail=30 > "$OUT/$v-bootlog.txt" 2>&1 || true
  shards="$(K exec deploy/durable-streams -c durable-streams -- sh -c 'cat /data/wal/shards 2>/dev/null' 2>/dev/null || echo '-')"
  echo "$v: persisted_shards=${shards:-none}" | tee -a "$OUT/shards.txt"

  echo "[$v] scaleout (cardinality ${MS_COUNTS}) at FIXED ${PARALLELISM:-1} pod(s)"
  # Capture WAL_STATS (server stdout, telemetry image) across the whole variant run.
  ( K logs -f deploy/durable-streams -c durable-streams 2>/dev/null | grep --line-buffered "WAL_STATS" > "$OUT/$v-walstats.txt" ) &
  wspid=$!
  PARALLELISM="${PARALLELISM:-1}" MAX_PODS="${MAX_PODS:-1}" MAX_BUMPS=0 bash scripts/gke-scaleout.sh slow > "$OUT/$v-scaleout.log" 2>&1
  kill "$wspid" 2>/dev/null; wait "$wspid" 2>/dev/null
  echo "[$v] WAL_STATS samples: $(wc -l < "$OUT/$v-walstats.txt" 2>/dev/null || echo 0); last:"; tail -2 "$OUT/$v-walstats.txt" 2>/dev/null
  mkdir -p "$OUT/$v/scaleout"
  so="$(grep -oE 'results/scaleout/[A-Za-z0-9._-]+' "$OUT/$v-scaleout.log" | tail -1)"
  [ -n "$so" ] && [ -d "$so" ] && mv "$so" "$OUT/$v/scaleout/"
  echo "[$v] done (shards=${shards}, scaleout=${so:-none})"
done

echo "=== rendering ==="
python3 scripts/gen-report.py "$OUT" 2>/dev/null || echo "WARN: render failed; raw under $OUT"
echo "=== shard counts ==="; cat "$OUT/shards.txt" 2>/dev/null
echo "WAL SHARD-SWEEP DONE → $OUT  (teardown on exit)"
