#!/usr/bin/env bash
# 2026-07-08 wal-vs-memory write campaign: 4 and 8 server vCPUs in parallel
# (each suite pins its own cluster/zone). Images are prebuilt from
# vb/ds-rust-memory-meta-sweep — this script NEVER rebuilds them.
#
#   nohup bash scripts/run-wal-vs-mem-20260708.sh > /tmp/walmem-campaign.log 2>&1 &
#
# Self-arms the teardown watchdog; verifies no bench-* clusters remain at exit.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PROJECT="${PROJECT:-vaxine}"
DONE_MARKER="$PWD/.bench-state/walmem-20260708.done"
rm -f "$DONE_MARKER"

# Watchdog: force-delete all bench-* clusters at the deadline unless we finish.
DEADLINE_SECS="${DEADLINE_SECS:-14400}" DONE_MARKER="$DONE_MARKER" \
  nohup bash scripts/teardown-watchdog.sh > /tmp/walmem-watchdog.log 2>&1 &
echo "watchdog armed (${DEADLINE_SECS:-14400}s)"

run_suite() {
  local suite="$1"
  DS_TARGET=remote PROJECT="$PROJECT" scripts/bench "suites/${suite}.json" run
  echo "[$suite] rc=$?"
}

run_suite write-wal-vs-mem-cpu4 > /tmp/walmem-cpu4.log 2>&1 &
p4=$!
run_suite write-wal-vs-mem-cpu8 > /tmp/walmem-cpu8.log 2>&1 &
p8=$!
wait "$p4"; wait "$p8"

touch "$DONE_MARKER"   # watchdog stands down

echo "== final cluster sweep =="
gcloud container clusters list --project "$PROJECT" \
  --format='value(name,location,status)' | grep -i bench || echo "no bench clusters remain"
