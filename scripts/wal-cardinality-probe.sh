#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# wal-cardinality-probe.sh — reproduce the WAL high-cardinality scaling cliff
# LOCALLY under Docker (Linux `fdatasync` = fast fsync, the regime where the cliff
# appears — unlike the Mac `F_FULLFSYNC` direct bench) and discriminate its cause
# via a SHARD SWEEP.
#
#   server: `docker run durable-streams:dev --durability <mode> [--wal-shards N]`
#   load:   native `ds-bench multi-stream` (Rust) — one writer task per stream, flat out.
#
# If `wal` cliffs vs `strict` here and MORE SHARDS move the cliff, the cause is the
# per-shard funnel / thundering-herd wakeup; if more shards doesn't help, it's a
# per-commit serialization independent of shard count.
#
#   [CARDS="100 1000 10000"] [DUR=10] [PAYLOAD=256] scripts/wal-cardinality-probe.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
DSB=./ds-bench/target/release/ds-bench
IMG=durable-streams:dev
PORT="${PORT:-4480}"
CARDS="${CARDS:-100 1000 10000}"
DUR="${DUR:-10}"
PAYLOAD="${PAYLOAD:-256}"
[ -x "$DSB" ] || { echo "build ds-bench: ( cd ds-bench && cargo build --release )" >&2; exit 1; }

# label | server durability args
CONFIGS=(
  "strict|--durability strict"
  "fast|--durability fast"
  "wal4|--durability wal --wal-shards 4"
  "wal16|--durability wal --wal-shards 16"
  "wal64|--durability wal --wal-shards 64"
)

printf '%-8s %-7s %12s %10s %10s %8s\n' config streams ops/s p99_ms cpu% shards
echo "------------------------------------------------------------------"
for cfg in "${CONFIGS[@]}"; do
  label="${cfg%%|*}"; args="${cfg#*|}"
  docker rm -f wcp >/dev/null 2>&1
  # TMPFS=1 → /data on RAM so fdatasync is ~instant (simulates infinitely-fast
  # storage), isolating the NON-fsync serialization (the GKE fast-storage regime).
  tmpfs_arg=(); [ -n "${TMPFS:-}" ] && tmpfs_arg=(--tmpfs "/data:rw,size=${TMPFS_SIZE:-4g}")
  # shellcheck disable=SC2086
  docker run -d --name wcp -p "${PORT}:4438" "${tmpfs_arg[@]}" "$IMG" \
    --host 0.0.0.0 --port 4438 --data-dir /data $args >/dev/null 2>&1
  # wait ready
  ok=0; for _ in $(seq 1 50); do curl -s -o /dev/null --max-time 1 "http://localhost:${PORT}/health" 2>/dev/null && { ok=1; break; }; sleep 0.2; done
  [ "$ok" = 1 ] || { echo "$label: server not ready"; docker logs wcp 2>&1 | tail -3; continue; }
  shards="$(docker exec wcp sh -c 'cat /data/wal/shards 2>/dev/null' 2>/dev/null || echo '-')"
  for card in $CARDS; do
    # Sample container CPU% DURING the run (peak of a few samples), not after.
    ( for _ in $(seq 1 $((DUR-2))); do docker stats wcp --no-stream --format '{{.CPUPerc}}'; done ) > /tmp/wcp-cpu.txt 2>/dev/null &
    cpid=$!
    out="$(timeout $((DUR+50)) "$DSB" multi-stream --target "http://localhost:${PORT}" \
            --api-style durable --streams "$card" --duration-secs "$DUR" \
            --payload-bytes "$PAYLOAD" --rate-per-stream 0 --setup-concurrency 256 2>/dev/null)"
    kill "$cpid" 2>/dev/null; wait "$cpid" 2>/dev/null
    ops="$(printf '%s' "$out" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(round(d["aggregate_ops_per_sec"]))' 2>/dev/null || echo '?')"
    p99="$(printf '%s' "$out" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(round(d["latency_ms"]["p99_ms"],1))' 2>/dev/null || echo '?')"
    cpu="$(tr -d '% ' < /tmp/wcp-cpu.txt 2>/dev/null | sort -n | tail -1 || echo '-')"
    printf '%-8s %-7s %12s %10s %9s%% %8s\n' "$label" "$card" "$ops" "$p99" "${cpu:--}" "${shards:--}"
  done
done
docker rm -f wcp >/dev/null 2>&1
echo "=== probe done ==="
