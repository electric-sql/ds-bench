#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# gke-compare-seq.sh — SEQUENTIAL, same-cluster A/B/N comparison.
#
# Unlike the parallel gke-compare-*.sh runners (one cluster per variant, run
# concurrently), this brings up ONE cluster and runs the variants one after another
# on the SAME node / SAME local SSD / SAME client pool, with a clean server redeploy
# between them. That removes the inter-cluster hardware/run variance that muddies
# tight A/Bs — e.g. strict vs relaxed at high cardinality, where the real effect is
# within parallel-run noise. The ONLY difference between variant runs is the server
# flag, so the diff is the flag.
#
# Clean slate per variant: the server deployment is deleted before each variant, so
# the next deploy gets a FRESH /data emptyDir (new pod). Multi-stream payloads never
# reach the seal threshold (8 MiB/stream) so they never touch the shared cold tier;
# the only cold-offloading cell (append) uses run-id-unique stream names. So there is
# no cross-variant contamination via MinIO — no bucket wipe needed.
#
# Cost note: sequential ≈ same cluster-hours as the N-parallel-cluster version (1
# cluster × N× time ≈ N clusters × 1× time), just longer wall-clock — bought in
# exchange for a low-noise comparison.
#
#   [VARIANTS="strict relaxed"] [SERVER_CPU=4] [DURATION=25] scripts/gke-compare-seq.sh
#
# Output: results/compare/seq-cpu<C>-<ts>/<variant>/{rawpower,scaleout}/... + REPORT.md
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PROJECT="${PROJECT:-vaxine}"
REG="europe-west1-docker.pkg.dev/${PROJECT}/ds-bench"
SERVER_CPU="${SERVER_CPU:-4}"; SERVER_MEM="${SERVER_MEM:-16Gi}"
CLUSTER="${CLUSTER:-ds-cmp-seq}"; ZONE="${ZONE:-europe-west1-d}"
SAFETYNET_SECS="${SAFETYNET_SECS:-14400}"   # 4h hard cap (sequential = longer wall-clock)
VARIANTS="${VARIANTS:-strict relaxed}"
TS="$(date +%s)"
OUT="results/compare/seq-cpu${SERVER_CPU}-${TS}"
mkdir -p "$OUT"

# Env the runners + lib-bench need (set BEFORE sourcing lib-bench → target-env).
export DS_TARGET=remote PROJECT ZONE CLUSTER
export SERVER_CPUS="$SERVER_CPU" SERVER_MEM
export LOCAL_SSD_COUNT="${LOCAL_SSD_COUNT:-1}" CLIENT_NODES="${CLIENT_NODES:-4}"
# shellcheck source=scripts/lib-bench.sh
. scripts/lib-bench.sh   # gives K() + KCTX + ensure_metrics_configmap (sources target-env)

echo "SEQ compare → $OUT (cluster=$CLUSTER@$ZONE, cpu=$SERVER_CPU, mem=$SERVER_MEM); variants=[$VARIANTS]"

# ── hard-cap safety-net + guaranteed single-cluster teardown on exit ──────────
( sleep "$SAFETYNET_SECS"
  echo "[safety-net] hard cap reached — force-deleting $CLUSTER" >&2
  gcloud container clusters delete "$CLUSTER" --zone "$ZONE" --project "$PROJECT" --quiet 2>/dev/null ) &
NETPID=$!
trap 'DS_TARGET=remote PROJECT="$PROJECT" CLUSTER="$CLUSTER" ZONE="$ZONE" bash scripts/cluster-down.sh >/dev/null 2>&1; kill "$NETPID" 2>/dev/null' EXIT

# name -> extra-server-args | SERVER_KIND | TARGET | API_STYLE | PROBE_HOSTPORT
spec_for() {
  case "$1" in
    strict)    echo "--durability strict|durable|http://durable-streams:4438|durable|durable-streams:4438" ;;
    fast)      echo "--durability fast|durable|http://durable-streams:4438|durable|durable-streams:4438" ;;
    relaxed)   echo "--durability relaxed|durable|http://durable-streams:4438|durable|durable-streams:4438" ;;
    wal)       echo "--durability wal|durable|http://durable-streams:4438|durable|durable-streams:4438" ;;
    reference) echo "|durable|http://durable-streams:4438|durable|durable-streams:4438" ;;
    *) echo ""; return 1 ;;
  esac
}

bash scripts/cluster-up.sh > "$OUT/cluster-up.log" 2>&1 || { echo "cluster-up FAILED — see $OUT/cluster-up.log"; exit 1; }

# Shared cell matrix + budgets (identical for every variant).
export FLEET_TIMEOUT=360 COORD_TIMEOUT=120 DURATION="${DURATION:-25}" REPEATS="${REPEATS:-1}"
export READ_SIZES="1024" READ_CONNS="256" APPEND_PAYLOADS="1024" APPEND_CONNS="256" \
       FO_SUBS_LIST="1 10 100" SKIP_SPLICE=1 SKIP_COLD=1
export MS_COUNTS="10 100 1000 10000" MF_PAIRS="10:10"

for v in $VARIANTS; do
  spec="$(spec_for "$v")" || { echo "unknown variant '$v' — skipping"; continue; }
  IFS='|' read -r xargs_ kind target api probe <<<"$spec"
  echo "════════════════════════════════════════════════════════════════════"
  echo "=== variant: $v  (extra='${xargs_:-none}') ==="
  echo "════════════════════════════════════════════════════════════════════"
  export SERVER_KIND="$kind" SERVER_EXTRA_ARGS="$xargs_" IMG_SERVER="${REG}/durable-streams:dev"
  export TARGET="$target" API_STYLE="$api" PROBE_HOSTPORT="$probe"

  # Clean slate: drop the previous variant's server so the next deploy gets a fresh
  # /data emptyDir (new pod). The runners' deploy_server re-creates it with $v's args.
  K delete deploy/durable-streams --ignore-not-found --wait=true >/dev/null 2>&1 || true

  echo "[$v] phase 1 rawpower"
  PARALLELISM=4 MAX_PODS=24 MAX_BUMPS=3 bash scripts/gke-rawpower.sh slow > "$OUT/$v-rawpower.log" 2>&1
  echo "[$v] phase 2 scaleout (cardinality sweep)"
  PARALLELISM=1 MAX_PODS=1 MAX_BUMPS=0 bash scripts/gke-scaleout.sh slow > "$OUT/$v-scaleout.log" 2>&1

  mkdir -p "$OUT/$v/rawpower" "$OUT/$v/scaleout"
  rp="$(grep -oE 'results/rawpower/[A-Za-z0-9._-]+' "$OUT/$v-rawpower.log" | tail -1)"
  so="$(grep -oE 'results/scaleout/[A-Za-z0-9._-]+' "$OUT/$v-scaleout.log" | tail -1)"
  [ -n "$rp" ] && [ -d "$rp" ] && mv "$rp" "$OUT/$v/rawpower/"
  [ -n "$so" ] && [ -d "$so" ] && mv "$so" "$OUT/$v/scaleout/"
  echo "[$v] done"
done

echo "=== rendering report ==="
python3 scripts/gen-report.py "$OUT" 2>/dev/null \
  || python3 scripts/compare-impls.py "$OUT" 2>/dev/null \
  || echo "WARN: render failed; raw data under $OUT"
echo "SEQ COMPARE DONE → $OUT  (teardown on exit)"
