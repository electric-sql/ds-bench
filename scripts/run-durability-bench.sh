#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# run-durability-bench.sh — quick SINGLE-MACHINE durability comparison.
#
# Starts a LOCAL durable-streams server (the release binary, NOT k8s) for each
# durability mode in turn — fresh /data, one port, sequentially — and drives
# scripts/bench-durability.mjs against it (single-stream + multi-stream append
# load, p50/p99). No kind, no cloud: a fast, low-noise read on the pure fsync
# cost of strict vs wal vs fast. (For the full k8s cardinality sweep use
# scripts/local-compare-durability.sh.)
#
# FIRST rebuild the server with your branch:
#   ( cd ../durable-streams/packages/server-rust && cargo build --release )
# then:
#   [MODES="strict wal fast"] [WAL_SHARDS=4] [DURATION_MS=6000] [PORT=4471] \
#     scripts/run-durability-bench.sh
#
# Caveats: Node load-gen caps the no-fsync (`fast`) throughput (client-bound, not
# server-bound); the strict/wal cells are fsync-bound so their RELATIVE compare is
# the trustworthy part. macOS fsync = F_FULLFSYNC (true power-loss durable).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${BIN:-${HERE}/../../durable-streams/packages/server-rust/target/release/durable-streams-server}"
MODES="${MODES:-strict wal fast}"
WAL_SHARDS="${WAL_SHARDS:-4}"
PORT="${PORT:-4471}"
export DURATION_MS="${DURATION_MS:-6000}"

[ -x "$BIN" ] || { echo "server binary not found/executable: $BIN" >&2; echo "build it: ( cd ../durable-streams/packages/server-rust && cargo build --release )" >&2; exit 1; }

for mode in $MODES; do
  dir="/tmp/ds-bench-$mode"; rm -rf "$dir"; mkdir -p "$dir"
  args=(--host 127.0.0.1 --port "$PORT" --data-dir "$dir" --durability "$mode")
  [ "$mode" = wal ] && args+=(--wal-shards "$WAL_SHARDS")
  "$BIN" "${args[@]}" > "/tmp/ds-srv-$mode.log" 2>&1 &
  srvpid=$!
  ok=0
  for _ in $(seq 1 60); do
    curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/health" 2>/dev/null && { ok=1; break; }
    sleep 0.2
  done
  if [ "$ok" != 1 ]; then echo "[$mode] server NOT ready:"; tail -5 "/tmp/ds-srv-$mode.log"; kill "$srvpid" 2>/dev/null; continue; fi
  BASE="http://127.0.0.1:$PORT" LABEL="$mode" node "${HERE}/bench-durability.mjs"
  kill "$srvpid" 2>/dev/null; wait "$srvpid" 2>/dev/null
  sleep 1
done
echo "=== durability bench done (modes: $MODES, shards=$WAL_SHARDS) ==="
