#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Usage / dispatch
out="$(scripts/bench 2>&1 || true)"
echo "$out" | grep -qi "usage" || { echo "FAIL: no usage on no args"; exit 1; }

# teardown reads only the suite's recorded clusters (dry-run)
mkdir -p .bench-state
echo '{"clusters":[{"name":"bench-wal","zone":"europe-west4-a"}]}' > .bench-state/write-throughput.json
out="$(BENCH_DRYRUN=1 scripts/bench suites/write-throughput.json teardown)"
echo "$out" | grep -q "clusters delete bench-wal" || { echo "FAIL: teardown wrong cluster"; exit 1; }
echo "$out" | grep -q "bench-ursula" && { echo "FAIL: teardown touched a cluster it didn't create"; exit 1; }
rm -f .bench-state/write-throughput.json
echo "PASS bench dispatch+teardown"
