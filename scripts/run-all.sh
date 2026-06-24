#!/usr/bin/env bash
# run-all.sh — run every write-throughput suite SEQUENTIALLY, unattended, with a
# GUARANTEED teardown after each (regardless of error cells), then emit the
# combined cross-configuration report. Designed to be launched detached and left
# to complete. A separate watchdog (scripts/teardown-watchdog.sh) force-deletes
# any leftover clusters at a hard deadline if this script ever hangs.
#
# Env:
#   SUITES   space-separated suite paths (default: the three write-throughput suites)
#   PER_SUITE_TIMEOUT  seconds before a single suite's run is killed (default 7200)
#   DONE_MARKER        file touched when ALL suites are done + torn down (watchdog watches it)
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(pwd)"

# Images are pushed once before this run and FIXED throughout, so reuse the
# node-cached image on every per-rung server restart instead of re-pulling from
# AR (~2 min/restart saved). Exported so cluster-up + every deploy inherit it.
export PULL_POLICY="${PULL_POLICY:-IfNotPresent}"

SUITES="${SUITES:-suites/write-throughput-wal.json suites/write-throughput-ursula.json suites/write-throughput-s2.json}"
PER_SUITE_TIMEOUT="${PER_SUITE_TIMEOUT:-10800}"
DONE_MARKER="${DONE_MARKER:-$REPO_ROOT/.bench-state/run-all.done}"
TIMEOUT_BIN="$(command -v gtimeout || command -v timeout || true)"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

teardown_suite() {  # always attempt teardown; never fatal
  local suite="$1"
  log "TEARDOWN $suite"
  scripts/bench "$suite" teardown || log "WARN: teardown failed for $suite"
}

rm -f "$DONE_MARKER"
log "run-all start — suites: $SUITES"

for suite in $SUITES; do
  [ -f "$suite" ] || { log "SKIP missing suite $suite"; continue; }
  log "RUN $suite (timeout ${PER_SUITE_TIMEOUT}s)"
  # BENCH_KEEP_CLUSTER=1: the run must NOT auto-teardown (that keeps the cluster on
  # error cells like a 100k choke). We ALWAYS teardown explicitly afterwards so an
  # expected error never strands a cluster.
  if [ -n "$TIMEOUT_BIN" ]; then
    BENCH_KEEP_CLUSTER=1 "$TIMEOUT_BIN" "$PER_SUITE_TIMEOUT" scripts/bench "$suite" run \
      || log "WARN: run for $suite exited non-zero / timed out"
  else
    BENCH_KEEP_CLUSTER=1 scripts/bench "$suite" run \
      || log "WARN: run for $suite exited non-zero"
  fi
  teardown_suite "$suite"
done

# Belt-and-suspenders: delete ANY bench-* clusters still standing (covers ERROR
# state or clusters whose state file was lost).
log "sweep: deleting any remaining bench-* clusters"
gcloud container clusters list --format='value(name,zone)' 2>/dev/null | grep -E '^bench-' \
  | while read -r name zone; do
      log "  sweep-delete $name ($zone)"
      gcloud container clusters delete "$name" --zone "$zone" --quiet || log "  WARN: sweep-delete $name failed"
    done

log "generating combined report"
python3 scripts/combined_report.py $SUITES || log "WARN: combined report failed"

touch "$DONE_MARKER"
log "run-all DONE — marker: $DONE_MARKER"
