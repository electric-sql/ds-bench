#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# gke-scaleout.sh — Phase 2: multi-stream scale-out.
#   multi-stream writes (sweep N streams) + multi-fanout (sweep M streams ×
#   S subscribers), headroom-guarded. Engine in scripts/lib-bench.sh; this file
#   is the Phase-2 MATRIX only.
#
# Usage:  [DS_TARGET=local|remote] scripts/gke-scaleout.sh [fast|slow]
# Env knobs: PARALLELISM REPEATS MAX_BUMPS FLEET_TIMEOUT COORD_TIMEOUT DS_TARGET.
#
# The slow caps (N≤200, M×S≤200) were set under the old ~1024-conn / ~200-create
# server limits. Those are now fixed server-side (raise NOFILE + create off the
# async pool), but the caps stay as SAFE DEFAULTS — raise them to chase true
# ceilings once you've re-confirmed the fixes hold.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

PROFILE="${1:-fast}"
case "$PROFILE" in
  fast|slow) ;;
  *) echo "ERROR: unknown profile '${PROFILE}' (supported: fast | slow)" >&2; exit 1 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=scripts/lib-bench.sh
. scripts/lib-bench.sh

SWEEP_RUN_ID="scaleout-${PROFILE}-$(date +%s)-$$"
RESULTS_ROOT="results/scaleout/${SWEEP_RUN_ID}"
mkdir -p "$RESULTS_ROOT"
# Target/api/probe are env-overridable so this matrix can run against the
# durable-streams server (default) OR ursula (TARGET=http://ursula:4437
# API_STYLE=ursula PROBE_HOSTPORT=ursula:4437 SERVER_KIND=ursula).
TARGET="${TARGET:-http://durable-streams:4438}"
API_STYLE="${API_STYLE:-durable}"
PROBE_HOSTPORT="${PROBE_HOSTPORT:-durable-streams:4438}"

# Server pinned to ONE size — no sweep. Default 4 cores / 16 GB; override
# SERVER_CPUS / SERVER_MEM for a larger machine (single value, not a list).
SERVER_CPUS="${SERVER_CPUS:-4}"; export SERVER_MEM="${SERVER_MEM:-16Gi}"
if [ "$PROFILE" = "fast" ]; then
  DURATION=15; REPEATS="${REPEATS:-1}"
  INIT_PARALLELISM="${PARALLELISM:-4}"; MAX_PODS=16; MAX_BUMPS="${MAX_BUMPS:-1}"
else
  DURATION="${DURATION:-25}"; REPEATS="${REPEATS:-3}"
  INIT_PARALLELISM="${PARALLELISM:-4}"; MAX_PODS="${MAX_PODS:-32}"; MAX_BUMPS="${MAX_BUMPS:-8}"
fi

echo "=== gke-scaleout: profile=${PROFILE} target=${DS_TARGET} run=${SWEEP_RUN_ID} ==="
echo "    SERVER_CPUS='${SERVER_CPUS}' DURATION=${DURATION} REPEATS=${REPEATS}"
echo "    INIT_PARALLELISM=${INIT_PARALLELISM} MAX_PODS=${MAX_PODS} MAX_BUMPS=${MAX_BUMPS}"
echo ""

ensure_metrics_configmap

# ── matrix ───────────────────────────────────────────────────────────────────
for SERVER_CPU in $SERVER_CPUS; do
  echo ""
  echo "════════════════════════════════════════════════════════════════════════"
  echo "=== deploying server: SERVER_CPU=${SERVER_CPU} ==="
  echo "════════════════════════════════════════════════════════════════════════"
  deploy_server "$SERVER_CPU"

  # ── multi-stream writes — sweep stream count N ──────────────────────────────
  if [ "$PROFILE" = "fast" ]; then MS_COUNTS="10 100"; else MS_COUNTS="${MS_COUNTS:-10 50 100 200}"; fi
  for N in $MS_COUNTS; do
    cell="ms-cpu${SERVER_CPU}-n${N}"
    bench_cmd="multi-stream --target ${TARGET} --api-style ${API_STYLE} --streams ${N} --duration-secs ${DURATION} --payload-bytes 256"
    # multi_stream emits `multi-stream-<pid>.hdr`; the HDR latency filter must match
    # that stem (the old `ms-` matched nothing → p99=0). Throughput is independent.
    run_cell "$cell" "$bench_cmd" "ms" "ds-bench hdr-merge --hdr-dir /merge --results-dir /merge --label-prefix multi-stream-" "$SERVER_CPU"
  done

  # ── multi-fanout — sweep (M streams × S subscribers) ────────────────────────
  if [ "$PROFILE" = "fast" ]; then MF_PAIRS="10:10"; else MF_PAIRS="${MF_PAIRS:-10:10 20:10 10:20}"; fi
  for ms_pair in $MF_PAIRS; do
    M="${ms_pair%%:*}"; S="${ms_pair##*:}"
    cell="multi-fanout-cpu${SERVER_CPU}-m${M}-s${S}"
    bench_cmd="multi-fanout --target ${TARGET} --api-style ${API_STYLE} --streams ${M} --subscribers-per-stream ${S} --writer-rate 50 --duration-secs ${DURATION}"
    run_cell "$cell" "$bench_cmd" "multi-fanout" "ds-bench hdr-merge --hdr-dir /merge --results-dir /merge --label-prefix multi-fanout-" "$SERVER_CPU"
  done
done

echo ""
echo "=== gke-scaleout ${PROFILE} complete. Results in ${RESULTS_ROOT}/ ==="
