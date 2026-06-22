#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# local-compare-durability.sh — LOCAL (kind) sequential 3-way comparison of the
# durability modes:  --durability strict | wal | fast.
#
# One kind cluster, same node / same disk / same client pool; the server is
# redeployed per variant with a FRESH /data emptyDir and the ONLY difference is
# the durability flag. Modest cell matrix sized for a single-node Docker-Desktop
# box (client fleet + server share the node, so ABSOLUTE numbers conflate the two
# — the RELATIVE strict/wal/fast deltas under identical contention are the signal).
#
# Mirrors gke-compare-seq.sh but for DS_TARGET=local (no cloud, no billing, no
# gcloud teardown — the kind cluster is left up for reuse).
#
#   [VARIANTS="strict wal fast"] [SERVER_CPU=4] [SERVER_MEM=4Gi] [DURATION=15] \
#     scripts/local-compare-durability.sh
#
# Output: results/compare/local-dur-cpu<C>-<ts>/<variant>/{rawpower,scaleout}/... + REPORT.md
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

export DS_TARGET=local
KIND_CLUSTER="${KIND_CLUSTER:-ds-bench}"; export KIND_CLUSTER
SERVER_CPU="${SERVER_CPU:-4}"
export SERVER_MEM="${SERVER_MEM:-4Gi}"          # node has ~7.6 GiB; request is 2Gi
WAL_SHARDS="${WAL_SHARDS:-4}"
VARIANTS="${VARIANTS:-strict wal fast}"
TS="$(date +%s)"
OUT="results/compare/local-dur-cpu${SERVER_CPU}-${TS}"
mkdir -p "$OUT"

export SERVER_CPUS="$SERVER_CPU"
# shellcheck source=scripts/lib-bench.sh
. scripts/lib-bench.sh   # K() + KCTX + ensure_metrics_configmap (sources target-env → local)

echo "LOCAL durability compare → $OUT (kind=$KIND_CLUSTER, cpu=$SERVER_CPU, mem=$SERVER_MEM); variants=[$VARIANTS]"

# Leave the kind cluster up; just drop the server deploy on exit so we don't leak the pod.
trap 'K delete deploy/durable-streams --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT

# name -> extra-server-args
spec_for() {
  case "$1" in
    strict) echo "--durability strict" ;;
    wal)    echo "--durability wal --wal-shards ${WAL_SHARDS}" ;;
    fast)   echo "--durability fast" ;;
    *) echo ""; return 1 ;;
  esac
}

# Target/probe are the durable-streams service (local manifests).
export TARGET="http://durable-streams:4438" API_STYLE="durable" PROBE_HOSTPORT="durable-streams:4438"
export SERVER_KIND="durable"

ensure_metrics_configmap

# Shared cell matrix + budgets (identical for every variant) — modest for single-node.
export FLEET_TIMEOUT=240 COORD_TIMEOUT=120 DURATION="${DURATION:-15}" REPEATS="${REPEATS:-1}"
export PARALLELISM="${PARALLELISM:-2}" MAX_PODS="${MAX_PODS:-8}" MAX_BUMPS="${MAX_BUMPS:-1}"
# rawpower: reads (durability-neutral, regression check) + single-stream micro append
# (conn=1 = the per-op-tax cell, spec §14c) + a contended append (conn=64) + small fan-out.
export READ_SIZES="1024" READ_CONNS="64" \
       APPEND_PAYLOADS="1024" APPEND_CONNS="1 64" \
       FO_SUBS_LIST="10" SKIP_SPLICE=1 SKIP_COLD=1
# scaleout: the cardinality sweep — where strict vs wal/fast diverges (fsync pacing).
export MS_COUNTS="10 100 1000" MF_PAIRS="10:10"

for v in $VARIANTS; do
  xargs_="$(spec_for "$v")" || { echo "unknown variant '$v' — skipping"; continue; }
  echo "════════════════════════════════════════════════════════════════════"
  echo "=== variant: $v  (extra='${xargs_}') ==="
  echo "════════════════════════════════════════════════════════════════════"
  export SERVER_EXTRA_ARGS="$xargs_"

  # Clean slate: drop the previous variant's server → next deploy gets a fresh /data.
  K delete deploy/durable-streams --ignore-not-found --wait=true >/dev/null 2>&1 || true

  echo "[$v] phase 1 rawpower (reads + single-stream micro append + contended append + fan-out)"
  bash scripts/gke-rawpower.sh slow > "$OUT/$v-rawpower.log" 2>&1
  echo "[$v] phase 2 scaleout (cardinality sweep 10/100/1000)"
  PARALLELISM=1 MAX_PODS=1 MAX_BUMPS=0 bash scripts/gke-scaleout.sh slow > "$OUT/$v-scaleout.log" 2>&1

  mkdir -p "$OUT/$v/rawpower" "$OUT/$v/scaleout"
  rp="$(grep -oE 'results/rawpower/[A-Za-z0-9._-]+' "$OUT/$v-rawpower.log" | tail -1)"
  so="$(grep -oE 'results/scaleout/[A-Za-z0-9._-]+' "$OUT/$v-scaleout.log" | tail -1)"
  [ -n "$rp" ] && [ -d "$rp" ] && mv "$rp" "$OUT/$v/rawpower/"
  [ -n "$so" ] && [ -d "$so" ] && mv "$so" "$OUT/$v/scaleout/"
  echo "[$v] done (rawpower=${rp:-none} scaleout=${so:-none})"
done

echo "=== rendering report ==="
python3 scripts/gen-report.py "$OUT" 2>"$OUT/render.err" \
  || { echo "WARN: gen-report failed (see $OUT/render.err); raw data under $OUT"; }
echo "LOCAL DURABILITY COMPARE DONE → $OUT"
