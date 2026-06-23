#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# gke-cache-compare.sh — resident tail-cache vs always-`sendfile` READ comparison
# on Linux. Deploys durable-streams (wal) with the tail cache OFF (the new Linux
# default) then ON (`--tail-cache-bytes 65536`), and drives an SSE fan-out over
# STREAMS streams — each event delivery reads that stream's freshly-appended tail,
# which is a resident-cache hit when ON and a `sendfile` (file) read when OFF.
# Records delivery throughput (ev/s) + delivery p99. Assumes the cluster is UP.
#
#   [STREAMS=10000] [SUBS=1] [RATE=10] CLUSTER=ds-bench-cache ZONE=europe-west4-c \
#     IMG_SERVER=.../durable-streams:cache scripts/gke-cache-compare.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$(pwd)"; export REPO_ROOT
export DS_TARGET=remote PROJECT="${PROJECT:-vaxine}" ZONE="${ZONE:-europe-west4-c}" CLUSTER="${CLUSTER:-ds-bench-cache}"
export SERVER_CPUS=4 SERVER_MEM=16Gi
export IMG_SERVER="${IMG_SERVER:-europe-west1-docker.pkg.dev/vaxine/ds-bench/durable-streams:cache}"
# shellcheck source=scripts/lib-bench.sh
. scripts/lib-bench.sh

STREAMS="${STREAMS:-10000}"; SUBS="${SUBS:-1}"; RATE="${RATE:-10}"
export SWEEP_RUN_ID="cachecmp-$(date +%s)" RESULTS_ROOT="results/cache/cachecmp-$(date +%s)"; mkdir -p "$RESULTS_ROOT"
export MODE=calibrate MAX_BUMPS=0 REPEATS=1 DURATION="${DURATION:-20}"
export FLEET_TIMEOUT="${FLEET_TIMEOUT:-480}" COORD_TIMEOUT="${COORD_TIMEOUT:-180}" FLEET_CPU="${FLEET_CPU:-4}"
export TARGET=http://durable-streams:4438 API_STYLE=durable PROBE_HOSTPORT=durable-streams:4438 SERVER_KIND=durable
SUM="$RESULTS_ROOT/cache.tsv"; printf 'tail_cache\tstreams\tsubs\tev_per_s\tp99_ms\n' > "$SUM"
echo "tail-cache compare → $RESULTS_ROOT (streams=$STREAMS subs=$SUBS rate=$RATE, image=$IMG_SERVER)"
ensure_metrics_configmap

REPS="${REPS:-3}"
# Clean leftover comparison servers (e.g. a prior ursula/s2 on a reused cluster).
K delete deploy/ursula s2lite --ignore-not-found --wait=true >/dev/null 2>&1 || true
for cache in off on; do
  args="--durability wal --wal-shards 4"
  [ "$cache" = on ] && args="$args --tail-cache-bytes 65536"
  echo "════════ tail-cache=$cache ($args) — $REPS reps ════════"
  K delete deploy/durable-streams --ignore-not-found --wait=true >/dev/null 2>&1 || true
  SERVER_EXTRA_ARGS="$args" deploy_server 4 >&2 || { echo "[$cache] deploy failed"; continue; }
  evs=""; p99s=""
  for rep in $(seq 1 "$REPS"); do
    cell="cache-$cache-r$rep"
    bench="multi-fanout --target $TARGET --api-style $API_STYLE --streams $STREAMS --subscribers-per-stream $SUBS --writer-rate $RATE --duration-secs $DURATION --warmup-secs 10 --settle-secs 5"
    INIT_PARALLELISM=1 MAX_PODS=1 \
      run_cell "$cell" "$bench" "mf" "ds-bench hdr-merge --hdr-dir /merge --results-dir /merge --label-prefix multi-fanout-" 4 >&2 || true
    cd="$RESULTS_ROOT/$cell/rep1"
    ev="$(python3 scripts/saturation.py --merged "$cd/merged.json" --prev-thr 0 --cpu 0 --cores 1 2>/dev/null | awk '{print $2}')"
    p99="$(grep -oE '"p99_ms"[: ]*[0-9.]+' "$cd/merged.json" 2>/dev/null | grep -oE '[0-9.]+$' | head -1)"
    echo "  [$cache rep$rep] ev/s=$ev p99=$p99" >&2
    evs="$evs $ev"; p99s="$p99s $p99"
  done
  ev_avg="$(printf '%s\n' $evs | grep . | awk '{s+=$1;n++}END{if(n)printf "%.0f",s/n}')"
  p99_avg="$(printf '%s\n' $p99s | grep . | awk '{s+=$1;n++}END{if(n)printf "%.1f",s/n}')"
  printf '%s\t%s\t%s\t%s\t%s\n' "$cache" "$STREAMS" "$SUBS" "${ev_avg:-0}" "${p99_avg:-NA}" | tee -a "$SUM"
done

echo ""; echo "═══════ TAIL-CACHE COMPARE → $SUM ═══════"; column -t "$SUM"
echo "(cluster $CLUSTER still up — tear down when finished)"
