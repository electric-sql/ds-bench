#!/usr/bin/env bash
set -euo pipefail
# Usage: ./run-bench.sh <durable|ursula|s2>
SYS="${1:?usage: run-bench.sh <durable|ursula|s2>}"
case "$SYS" in
  durable) SVC=durable-streams; TARGET=http://durable-streams:4438; STYLE=durable; HOSTPORT=4438; BASIN_ARG="" ;;
  ursula)  SVC=ursula;          TARGET=http://ursula:4437;          STYLE=ursula;  HOSTPORT=4437; BASIN_ARG="" ;;
  s2)      SVC=s2lite;          TARGET=http://s2lite:80;            STYLE=s2;      HOSTPORT=4439; BASIN_ARG="--basin benchmark" ;;
  *) echo "unknown system: $SYS" >&2; exit 2 ;;
esac

# Identical workload parameters across systems (fairness).
STREAMS=200; DURATION=30; PAYLOAD=256
SUBSCRIBERS=500; WRITER_RATE=50
CU_CLIENTS=200; CU_PRE_EVENTS=2000; CU_EVENT_BYTES=1024

mkdir -p results
docker compose up -d minio
docker compose run --rm minio-init
echo "== starting $SVC (only server running) =="
docker compose up -d --build "$SVC"
echo "== waiting for $SVC to be ready on port $HOSTPORT =="
_ready=0
for _i in $(seq 1 60); do
  _code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HOSTPORT}/" || true)
  if [ "$_code" != "000" ]; then
    echo "  $SVC ready after ${_i}s (HTTP ${_code})"
    _ready=1
    break
  fi
  sleep 1
done
if [ "$_ready" -eq 0 ]; then
  echo "WARNING: $SVC did not respond on port $HOSTPORT after 60s — proceeding anyway" >&2
fi

run() { docker compose run --rm -T bench "$@"; }

echo "== multi-stream =="
run multi-stream --target "$TARGET" --api-style "$STYLE" $BASIN_ARG \
  --streams "$STREAMS" --duration-secs "$DURATION" --payload-bytes "$PAYLOAD" \
  > "results/${SYS}-multi-stream.json"

echo "== fan-out =="
run fan-out --target "$TARGET" --api-style "$STYLE" $BASIN_ARG \
  --subscribers "$SUBSCRIBERS" --writer-rate "$WRITER_RATE" --duration-secs "$DURATION" \
  --payload-bytes "$PAYLOAD" > "results/${SYS}-fanout.json"

if [ "$SYS" != "s2" ]; then
  echo "== catch-up =="
  run catch-up --target "$TARGET" --api-style "$STYLE" $BASIN_ARG \
    --clients "$CU_CLIENTS" --pre-events "$CU_PRE_EVENTS" --event-bytes "$CU_EVENT_BYTES" \
    > "results/${SYS}-catch-up.json"
else
  echo "== catch-up: SKIPPED for s2 (paginated, JSON-enveloped read — not comparable) =="
fi

echo "== stopping $SVC =="
docker compose stop "$SVC"
echo "results written to results/${SYS}-*.json"
