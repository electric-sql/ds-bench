#!/usr/bin/env bash
# run-zerocopy.sh — benchmark the zero-copy server build (one suite, two labels:
# --zero-copy ON vs OFF on the SAME new binary) with guaranteed teardown, then
# emit a comparison report. Writes ONLY to results/write-throughput-zerocopy/ and
# results/zerocopy-comparison.{md,csv}; does NOT touch any existing report.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(pwd)"

SUITE="suites/write-throughput-zerocopy.json"
BASELINE_SUITE="suites/write-throughput-wal.json"   # prior run (old binary) for cross-reference
ZC_IMAGE="${ZC_IMAGE:-europe-west1-docker.pkg.dev/vaxine/ds-bench/durable-streams:zerocopy}"
PER_SUITE_TIMEOUT="${PER_SUITE_TIMEOUT:-10800}"
DONE_MARKER="${DONE_MARKER:-$REPO_ROOT/.bench-state/zerocopy.done}"
TIMEOUT_BIN="$(command -v gtimeout || command -v timeout || true)"

# Fixed image for the whole run -> reuse node cache on per-rung restarts.
export PULL_POLICY="${PULL_POLICY:-IfNotPresent}"
# Point the server deploy at the zero-copy binary (target-env respects a preset).
export IMG_SERVER="$ZC_IMAGE"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

rm -f "$DONE_MARKER"
log "run-zerocopy start — IMG_SERVER=$IMG_SERVER"

log "RUN $SUITE (timeout ${PER_SUITE_TIMEOUT}s)"
if [ -n "$TIMEOUT_BIN" ]; then
  BENCH_KEEP_CLUSTER=1 "$TIMEOUT_BIN" "$PER_SUITE_TIMEOUT" scripts/bench "$SUITE" run \
    || log "WARN: run exited non-zero / timed out"
else
  BENCH_KEEP_CLUSTER=1 scripts/bench "$SUITE" run || log "WARN: run exited non-zero"
fi

log "TEARDOWN $SUITE"
scripts/bench "$SUITE" teardown || log "WARN: teardown failed"

# Scope the sweep to THIS run's cluster (mode wal -> bench-wal) so a parallel run's
# cluster (e.g. bench-ursula) is never deleted.
log "sweep: deleting any remaining bench-wal* clusters"
gcloud container clusters list --format='value(name,zone)' 2>/dev/null | grep -E '^bench-wal' \
  | while read -r name zone; do
      log "  sweep-delete $name ($zone)"
      gcloud container clusters delete "$name" --zone "$zone" --quiet || log "  WARN: sweep-delete $name failed"
    done

log "generating comparison report (zerocopy vs wal-newbin vs old wal/wal-tailcache)"
# Writes results/zerocopy-comparison.{md,csv} — NOT the existing results/combined-*.
COMBINED_OUT=zerocopy-comparison python3 scripts/combined_report.py "$SUITE" "$BASELINE_SUITE" \
  || log "WARN: comparison report failed"

touch "$DONE_MARKER"
log "run-zerocopy DONE — marker: $DONE_MARKER"
