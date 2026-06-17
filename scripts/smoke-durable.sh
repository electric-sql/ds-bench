#!/usr/bin/env bash
set -euo pipefail
# Usage: DS_SERVER_BIN=/path/to/durable-streams-server scripts/smoke-durable.sh
DS_BIN="${DS_SERVER_BIN:?set DS_SERVER_BIN to the durable-streams-server binary}"
BENCH="$(dirname "$0")/../ds-bench/target/release/ds-bench"
PORT=4470
BASE="http://127.0.0.1:${PORT}"
DATA="$(mktemp -d)"

MS_JSON=$(mktemp)
FO_JSON=$(mktemp)

"$DS_BIN" --host 127.0.0.1 --port "$PORT" --data-dir "$DATA" --tier off &
SRV=$!
trap 'kill $SRV 2>/dev/null || true; rm -rf "$DATA"; rm -f "$MS_JSON" "$FO_JSON"' EXIT
sleep 1

echo "== multi-stream =="
"$BENCH" multi-stream --target "$BASE" --api-style durable \
  --streams 4 --duration-secs 3 --payload-bytes 128 | tee "$MS_JSON"
test "$(jq '.counts.ok' "$MS_JSON")" -gt 0

echo "== fan-out =="
"$BENCH" fan-out --target "$BASE" --api-style durable \
  --subscribers 8 --writer-rate 50 --duration-secs 5 | tee "$FO_JSON"
test "$(jq '.events_received' "$FO_JSON")" -gt 0
test "$(jq '.fan_out_latency_ms.count' "$FO_JSON")" -gt 0

echo "ALL SMOKE CHECKS PASSED"
