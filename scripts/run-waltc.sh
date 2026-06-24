#!/usr/bin/env bash
# run-waltc.sh — benchmark the NEW (zero-copy) binary with zero-copy OFF + the
# resident tail cache ON (wal-newbin-tailcache: --wal-shards 4 --tail-cache-bytes
# 65536). Standalone so it doesn't re-walk the already-done zerocopy/wal-newbin
# cells. Guaranteed teardown; then regenerates results/zerocopy-comparison.* to
# include all three new-binary variants (+ old wal reference). Touches no other
# existing report. Uses cluster bench-wal (run AFTER the zerocopy run finished).
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(pwd)"

SUITE="suites/write-throughput-waltc.json"
ZC_SUITE="suites/write-throughput-zerocopy.json"       # zerocopy + wal-newbin (already run)
BASELINE_SUITE="suites/write-throughput-wal.json"      # old pre-CRC wal reference
ZC_IMAGE="${ZC_IMAGE:-europe-west1-docker.pkg.dev/vaxine/ds-bench/durable-streams:zerocopy}"
PER_SUITE_TIMEOUT="${PER_SUITE_TIMEOUT:-10800}"
DONE_MARKER="${DONE_MARKER:-$REPO_ROOT/.bench-state/waltc.done}"
TIMEOUT_BIN="$(command -v gtimeout || command -v timeout || true)"

export PULL_POLICY="${PULL_POLICY:-IfNotPresent}"
export IMG_SERVER="$ZC_IMAGE"     # same new binary; tail-cache is enabled via args

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

rm -f "$DONE_MARKER"
log "run-waltc start — IMG_SERVER=$IMG_SERVER"

log "RUN $SUITE (timeout ${PER_SUITE_TIMEOUT}s)"
if [ -n "$TIMEOUT_BIN" ]; then
  BENCH_KEEP_CLUSTER=1 "$TIMEOUT_BIN" "$PER_SUITE_TIMEOUT" scripts/bench "$SUITE" run \
    || log "WARN: run exited non-zero / timed out"
else
  BENCH_KEEP_CLUSTER=1 scripts/bench "$SUITE" run || log "WARN: run exited non-zero"
fi

log "TEARDOWN $SUITE"
scripts/bench "$SUITE" teardown || log "WARN: teardown failed"

log "sweep: deleting any remaining bench-wal* clusters"
gcloud container clusters list --format='value(name,zone)' 2>/dev/null | grep -E '^bench-wal' \
  | while read -r name zone; do
      log "  sweep-delete $name ($zone)"
      gcloud container clusters delete "$name" --zone "$zone" --quiet || log "  WARN: sweep-delete $name failed"
    done

# Regenerate the new-binary comparison to INCLUDE all three variants. This writes
# results/zerocopy-comparison.* only (this experiment's own report) — not the
# committed reports or results/combined-*.
log "regenerating zerocopy comparison (zerocopy / wal-newbin / wal-newbin-tailcache + old wal)"
COMBINED_OUT=zerocopy-comparison python3 scripts/combined_report.py "$ZC_SUITE" "$SUITE" "$BASELINE_SUITE" \
  || log "WARN: comparison report failed"

touch "$DONE_MARKER"
log "run-waltc DONE — marker: $DONE_MARKER"
