#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# local-cardinality.sh — multi-stream cardinality sweep on the LOCAL kind cluster,
# a 3-way comparison on ONE cluster, sequentially:
#   reference  = durable-streams, --wal off (today's per-stream group-commit)
#   wal-strict = durable-streams, --wal --wal-sync strict (shared-WAL group commit)
#   ursula     = ursula single-node (Raft disk WAL), --api-style ursula
# reference + wal-strict share ONE binary (the WAL branch; A/B by flag).
#
# WHY PARALLELISM=1: the `multi-stream` workload names streams `s%08d` and
# producer-ids `bench-{idx}` WITHOUT the pod index, so >1 fleet pod collides on
# identical (stream, producer, epoch, seq) and the server DEDUPS the duplicates —
# extra pods add no real durable load. One pod already drives one writer task per
# stream over an unbounded connection pool (build_client: pool_max_idle=MAX), so a
# single pod with --streams N is the correct, high-load way to exercise N-cardinality.
#
# This is a FUNCTIONAL + WIRING debug on the macOS Docker VM (shared CPU, non-NVMe
# fsync) — NOT a throughput measurement. Real numbers come from GKE. Ursula is
# built for multi-node; single-node here is a wiring check, not its strong suit.
#
#   [SERVER_CPU=4] [SERVER_MEM=4Gi] [DURATION=20] [MS_COUNTS="10 100 1000"] \
#     [VARIANTS_SEL="reference wal-strict ursula"] scripts/local-cardinality.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
export DS_TARGET=local
# shellcheck source=scripts/lib-bench.sh
. scripts/lib-bench.sh

# ── knobs (sized for the ~10-core / ~7.6 GiB Docker VM) ──────────────────────
SERVER_CPU="${SERVER_CPU:-4}"            # cgroup cpu.max for the server
export SERVER_MEM="${SERVER_MEM:-4Gi}"   # fits the VM (limit, not reservation)
DURATION="${DURATION:-20}"
REPEATS="${REPEATS:-1}"
MS_COUNTS="${MS_COUNTS:-10 100 1000}"
VARIANTS_SEL="${VARIANTS_SEL:-reference wal-strict ursula}"
# PARALLELISM is pinned to 1 (see header). No headroom bumping for multi-stream.
INIT_PARALLELISM=1; MAX_PODS=1; MAX_BUMPS=0
export FLEET_TIMEOUT="${FLEET_TIMEOUT:-360}" COORD_TIMEOUT="${COORD_TIMEOUT:-120}"

TS="$(date +%s)"
OUT="results/local-card-${TS}"
mkdir -p "$OUT"
echo "local 3-way cardinality → $OUT (cpu=${SERVER_CPU}, mem=${SERVER_MEM}, dur=${DURATION}s, N=[${MS_COUNTS}], variants=[${VARIANTS_SEL}])"

ensure_metrics_configmap

# Only one server fits on the tiny single node — delete any prior server first.
cleanup_servers() {
  K delete deploy/durable-streams deploy/ursula --ignore-not-found --wait=true >/dev/null 2>&1 || true
}

# name | kind | extra-args | TARGET | API_STYLE | PROBE_HOSTPORT
spec_for() {
  case "$1" in
    reference)  echo "durable||http://durable-streams:4438|durable|durable-streams:4438" ;;
    wal-strict) echo "durable|--wal --wal-sync strict|http://durable-streams:4438|durable|durable-streams:4438" ;;
    ursula)     echo "ursula||http://ursula:4437|ursula|ursula:4437" ;;
    strict)     echo "durable|--durability strict|http://durable-streams:4438|durable|durable-streams:4438" ;;
    relaxed)    echo "durable|--durability relaxed|http://durable-streams:4438|durable|durable-streams:4438" ;;
    *) echo ""; return 1 ;;
  esac
}

for variant in $VARIANTS_SEL; do
  spec="$(spec_for "$variant")" || { echo "unknown variant '$variant' — skipping"; continue; }
  IFS='|' read -r kind xargs_ vtarget vapi vprobe <<<"$spec"
  echo ""
  echo "════════════════════════════════════════════════════════════════════"
  echo "=== variant: ${variant}  kind=${kind}  extra='${xargs_:-none}' ==="
  echo "════════════════════════════════════════════════════════════════════"
  export SERVER_KIND="$kind"
  export SERVER_EXTRA_ARGS="$xargs_"
  TARGET="$vtarget"; API_STYLE="$vapi"; PROBE_HOSTPORT="$vprobe"
  SWEEP_RUN_ID="local-card-${variant}-${TS}"
  RESULTS_ROOT="${OUT}/${variant}"
  mkdir -p "$RESULTS_ROOT"

  cleanup_servers
  deploy_server "$SERVER_CPU"

  for N in $MS_COUNTS; do
    cell="ms-n${N}"
    bench_cmd="multi-stream --target ${TARGET} --api-style ${API_STYLE} --streams ${N} --duration-secs ${DURATION} --payload-bytes 256"
    run_cell "$cell" "$bench_cmd" "ms" "ds-bench hdr-merge --hdr-dir /merge --results-dir /merge --label-prefix multi-stream-" "$SERVER_CPU"
    # WAL telemetry (end-of-cell window) — only on the durable-streams --wal path.
    if [ "$kind" = "durable" ] && [ -n "$xargs_" ]; then
      K logs deploy/durable-streams -c durable-streams --tail=400 2>/dev/null \
        | grep WAL_STATS | tail -6 > "${RESULTS_ROOT}/${cell}/wal_stats.txt" || true
      echo "    WAL_STATS (end of cell):"; sed 's/^/      /' "${RESULTS_ROOT}/${cell}/wal_stats.txt" 2>/dev/null
    fi
  done
done

cleanup_servers
echo ""
echo "=== local 3-way cardinality complete → ${OUT} ==="