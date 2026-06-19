#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# gke-rawpower.sh — Phase 1: DS raw power (single-stream micro).
#   reads × size × conn, appends (bytes only) × conn × payload, fan-out × subs,
#   splice (1 MB binary), cold-tier read — swept across a SERVER_CPU budget and
#   scaled until server-bound (the headroom guard). The engine lives in
#   scripts/lib-bench.sh; this file is the Phase-1 MATRIX only.
#
# Usage:  [DS_TARGET=local|remote] scripts/gke-rawpower.sh [fast|slow]
#   fast — one CPU/dim point, 1 repeat, ≤1 pod-bump (smoke).
#   slow — CPU {2,4,8} × full dims, REPEATS repeats, bump to MAX_PODS.
# Env knobs: PARALLELISM REPEATS MAX_BUMPS FLEET_TIMEOUT COORD_TIMEOUT DS_TARGET.
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
. scripts/lib-bench.sh    # sources target-env.sh; defines K() + the engine

# ── run identity ─────────────────────────────────────────────────────────────
SWEEP_RUN_ID="rawpower-${PROFILE}-$(date +%s)-$$"
RESULTS_ROOT="results/rawpower/${SWEEP_RUN_ID}"
mkdir -p "$RESULTS_ROOT"
TARGET="http://durable-streams:4438"
API_STYLE="durable"
PROBE_HOSTPORT="durable-streams:4438"

# ── profile knobs ────────────────────────────────────────────────────────────
if [ "$PROFILE" = "fast" ]; then
  SERVER_CPUS="2"; DURATION=15; REPEATS=1
  INIT_PARALLELISM="${PARALLELISM:-4}"; MAX_PODS=16; MAX_BUMPS=1
else
  # CPU capped at 8 (the BENCHMARKS.md server scale) so it fits an 8-CPU node.
  SERVER_CPUS="${SERVER_CPUS:-2 4 8}"; DURATION="${DURATION:-30}"; REPEATS="${REPEATS:-3}"
  INIT_PARALLELISM="${PARALLELISM:-4}"; MAX_PODS="${MAX_PODS:-32}"; MAX_BUMPS="${MAX_BUMPS:-8}"
fi

echo "=== gke-rawpower: profile=${PROFILE} target=${DS_TARGET} run=${SWEEP_RUN_ID} ==="
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

  # ── reads: stream size IS the read size (full catch-up per GET) ─────────────
  if [ "$PROFILE" = "fast" ]; then READ_SIZES="1024";        READ_CONNS="256";
  else                            READ_SIZES="${READ_SIZES:-1024 16384}";   READ_CONNS="${READ_CONNS:-16 64 256}"; fi
  for read_size in $READ_SIZES; do
    for read_conn in $READ_CONNS; do
      cell="reads-cpu${SERVER_CPU}-size${read_size}-conn${read_conn}"
      bench_cmd="reads --target ${TARGET} --api-style ${API_STYLE} --stream ${cell}-${SWEEP_RUN_ID} --read-size-bytes ${read_size} --connections ${read_conn} --duration-secs ${DURATION} --seed-bytes ${read_size}"
      run_cell "$cell" "$bench_cmd" "reads" "ds-bench hdr-merge --hdr-dir /merge --results-dir /merge --label-prefix reads-" "$SERVER_CPU"
    done
  done

  # ── appends: BYTES ONLY (splice-eligible; JSON dropped from all phases) ──────
  if [ "$PROFILE" = "fast" ]; then APPEND_CONNS="256";    APPEND_PAYLOADS="1024";
  else                            APPEND_CONNS="${APPEND_CONNS:-64 256}";  APPEND_PAYLOADS="${APPEND_PAYLOADS:-1024 16384}"; fi
  for append_payload in $APPEND_PAYLOADS; do
    for append_conn in $APPEND_CONNS; do
      cell="append-cpu${SERVER_CPU}-conn${append_conn}-binary-p${append_payload}"
      bench_cmd="append --target ${TARGET} --api-style ${API_STYLE} --stream ${cell}-${SWEEP_RUN_ID} --connections ${append_conn} --payload-bytes ${append_payload} --duration-secs ${DURATION} --body-mode binary"
      run_cell "$cell" "$bench_cmd" "append" "ds-bench hdr-merge --hdr-dir /merge --results-dir /merge --label-prefix append-" "$SERVER_CPU"
    done
  done

  # ── splice variant (slow only): 1 MB binary with --splice-appends ───────────
  if [ "$PROFILE" = "slow" ] && [ "${SKIP_SPLICE:-0}" = "0" ]; then
    echo ""; echo "=== deploying splice-appends server variant (cpu=${SERVER_CPU}) ==="
    deploy_server "$SERVER_CPU" "--splice-appends"
    cell="append-splice-cpu${SERVER_CPU}-conn256-binary-1m"
    bench_cmd="append --target ${TARGET} --api-style ${API_STYLE} --stream ${cell}-${SWEEP_RUN_ID} --connections 256 --payload-bytes 1048576 --duration-secs ${DURATION} --body-mode binary"
    run_cell "$cell" "$bench_cmd" "append-splice" "ds-bench hdr-merge --hdr-dir /merge --results-dir /merge --label-prefix append-splice-" "$SERVER_CPU"
    echo "=== restoring standard server (cpu=${SERVER_CPU}) ==="
    deploy_server "$SERVER_CPU"
  fi

  # ── fan-out: 1 writer → N subscribers, end-to-end delivery latency ──────────
  if [ "$PROFILE" = "fast" ]; then FO_SUBS_LIST="256"; else FO_SUBS_LIST="${FO_SUBS_LIST:-1 10 100}"; fi
  for subs in $FO_SUBS_LIST; do
    cell="fanout-cpu${SERVER_CPU}-subs${subs}"
    bench_cmd="fan-out --target ${TARGET} --api-style ${API_STYLE} --stream ${cell}-${SWEEP_RUN_ID} --subscribers ${subs} --writer-rate 50 --duration-secs ${DURATION} --payload-bytes 1024"
    run_cell "$cell" "$bench_cmd" "fan-out" "ds-bench hdr-merge --hdr-dir /merge --results-dir /merge --label-prefix fanout-" "$SERVER_CPU"
  done

  # ── cold-tier read (slow only): --tier local, seed > hot cap (32 MiB) ───────
  if [ "$PROFILE" = "slow" ] && [ "${SKIP_COLD:-0}" = "0" ]; then
    echo ""; echo "=== deploying cold-tier server variant (cpu=${SERVER_CPU}) ==="
    deploy_server "$SERVER_CPU" "--tier local"
    cell="reads-cold-cpu${SERVER_CPU}-size1m-conn64"
    bench_cmd="reads --target ${TARGET} --api-style ${API_STYLE} --stream ${cell}-${SWEEP_RUN_ID} --read-size-bytes 1048576 --connections 64 --duration-secs ${DURATION} --seed-bytes 33554432"
    run_cell "$cell" "$bench_cmd" "reads-cold" "ds-bench hdr-merge --hdr-dir /merge --results-dir /merge --label-prefix reads-cold-" "$SERVER_CPU"
    echo "=== restoring standard server (cpu=${SERVER_CPU}) ==="
    deploy_server "$SERVER_CPU"
  fi
done

echo ""
echo "=== gke-rawpower ${PROFILE} complete. Results in ${RESULTS_ROOT}/ ==="
