#!/usr/bin/env bash
# run-ursula-memory.sh — benchmark ursula in IN-MEMORY mode (URSULA_WAL=memory,
# its non-durable best case) with guaranteed teardown, then a comparison report vs
# the disk-WAL ursula baseline. SAFE TO RUN IN PARALLEL with other bench runs: its
# teardown + sweep + watchdog target ONLY bench-ursula, never another run's cluster.
# Writes ONLY results/write-throughput-ursula-memory/ and
# results/ursula-memory-comparison.{md,csv}; touches no existing report.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(pwd)"

SUITE="suites/write-throughput-ursula-memory.json"
BASELINE_SUITE="suites/write-throughput-ursula.json"   # prior disk-WAL ursula run
PER_SUITE_TIMEOUT="${PER_SUITE_TIMEOUT:-10800}"
DONE_MARKER="${DONE_MARKER:-$REPO_ROOT/.bench-state/ursula-memory.done}"
TIMEOUT_BIN="$(command -v gtimeout || command -v timeout || true)"

export PULL_POLICY="${PULL_POLICY:-IfNotPresent}"
export URSULA_WAL="memory"          # <-- in-memory Raft WAL (no disk durability)

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

rm -f "$DONE_MARKER"
log "run-ursula-memory start — URSULA_WAL=$URSULA_WAL"

log "RUN $SUITE (timeout ${PER_SUITE_TIMEOUT}s)"
if [ -n "$TIMEOUT_BIN" ]; then
  BENCH_KEEP_CLUSTER=1 "$TIMEOUT_BIN" "$PER_SUITE_TIMEOUT" scripts/bench "$SUITE" run \
    || log "WARN: run exited non-zero / timed out"
else
  BENCH_KEEP_CLUSTER=1 scripts/bench "$SUITE" run || log "WARN: run exited non-zero"
fi

log "TEARDOWN $SUITE"
scripts/bench "$SUITE" teardown || log "WARN: teardown failed"

# Sweep ONLY bench-ursula (NEVER all bench-* — a parallel run owns bench-wal etc.)
log "sweep: deleting any remaining bench-ursula* clusters"
gcloud container clusters list --format='value(name,zone)' 2>/dev/null | grep -E '^bench-ursula' \
  | while read -r name zone; do
      log "  sweep-delete $name ($zone)"
      gcloud container clusters delete "$name" --zone "$zone" --quiet || log "  WARN: sweep-delete $name failed"
    done

log "generating comparison report (ursula-memory vs ursula disk-WAL baseline)"
COMBINED_OUT=ursula-memory-comparison python3 scripts/combined_report.py "$SUITE" "$BASELINE_SUITE" \
  || log "WARN: comparison report failed"

touch "$DONE_MARKER"
log "run-ursula-memory DONE — marker: $DONE_MARKER"
