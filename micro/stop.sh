#!/usr/bin/env bash
# Stop everything the bench started — TARGETED, never a broad killall.
#
#   bash stop.sh            # stop micro bench (orchestrator + server + our procs)
#   ALSO_CROSSSERVER=1 bash stop.sh   # also stop the cross-server run-all.sh tree
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/config.env" 2>/dev/null || true
PORT="${PORT:-4700}"
BIN="${BIN:-/usr/local/bin/durable-streams-server}"

echo "stopping bench (orchestrator, server, our procs)..."
# Stop the orchestrator first so it can't launch new cells, then the server.
pkill -f "micro/run.sh" 2>/dev/null
# Targeted mop-up by OUR specific cmdlines/port — NOT killall.
pkill -f "curl -s http://127.0.0.1:${PORT}" 2>/dev/null
pkill -f "$BIN" 2>/dev/null

if [ "${ALSO_CROSSSERVER:-0}" = 1 ]; then
  echo "stopping cross-server (run-all.sh) tree..."
  pkill -f "bench/run-all.sh" 2>/dev/null
  pkill -f "bench/node-server.ts" 2>/dev/null
  pkill -f "bench/scale-out.ts" 2>/dev/null
  pkill -f "vitest bench" 2>/dev/null
fi

sleep 1
echo "remaining=$(pgrep -fc 'micro/run.sh|'"$BIN" 2>/dev/null || echo 0)"
echo "done."
