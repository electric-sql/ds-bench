#!/usr/bin/env bash
# run-extend.sh — generic single-suite runner for a ladder-EXTENSION run (more
# clients / higher pod ladder to push a not-yet-plateaued cell to its plateau).
# Parallel-safe: teardown + sweep are scoped to THIS suite's own cluster
# (cluster.cluster_name), so it never touches another concurrent run's cluster.
# Writes only results/<suite>/. Guaranteed teardown + done marker for the watchdog.
#
# Env: SUITE (required), DONE_MARKER (required), and optionally IMG_SERVER /
#      URSULA_WAL (server selection), PER_SUITE_TIMEOUT.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

: "${SUITE:?set SUITE}"
: "${DONE_MARKER:?set DONE_MARKER}"
PER_SUITE_TIMEOUT="${PER_SUITE_TIMEOUT:-10800}"
TIMEOUT_BIN="$(command -v gtimeout || command -v timeout || true)"
export PULL_POLICY="${PULL_POLICY:-IfNotPresent}"

CNAME="$(python3 -c "import sys;sys.path.insert(0,'scripts');from suite import Suite;print(Suite.load('$SUITE').cluster.get('cluster_name',''))")"
[ -n "$CNAME" ] || { echo "ERROR: $SUITE has no cluster.cluster_name (needed for scoped sweep)"; exit 2; }

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
rm -f "$DONE_MARKER"
log "run-extend start — SUITE=$SUITE cluster=$CNAME IMG_SERVER=${IMG_SERVER:-<default>} URSULA_WAL=${URSULA_WAL:-<default>}"

log "RUN $SUITE (timeout ${PER_SUITE_TIMEOUT}s)"
if [ -n "$TIMEOUT_BIN" ]; then
  BENCH_KEEP_CLUSTER=1 "$TIMEOUT_BIN" "$PER_SUITE_TIMEOUT" scripts/bench "$SUITE" run || log "WARN: run non-zero/timeout"
else
  BENCH_KEEP_CLUSTER=1 scripts/bench "$SUITE" run || log "WARN: run non-zero"
fi

log "TEARDOWN $SUITE"
scripts/bench "$SUITE" teardown || log "WARN: teardown failed"

log "sweep: deleting any remaining ${CNAME}* clusters (scoped — never another run's)"
gcloud container clusters list --format='value(name,zone)' 2>/dev/null | grep -E "^${CNAME}" \
  | while read -r name zone; do
      log "  sweep-delete $name ($zone)"
      gcloud container clusters delete "$name" --zone "$zone" --quiet || log "  WARN: sweep-delete $name failed"
    done

touch "$DONE_MARKER"
log "run-extend DONE ($SUITE) — marker: $DONE_MARKER"
