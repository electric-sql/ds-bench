#!/usr/bin/env bash
# Phase 2 scale-out runner: stream-count sweep (multi-stream writes + multi-fanout),
# headroom-guarded, UNCAPPED (fleet scales until server is the bottleneck).
#
# Usage: gke-scaleout.sh [fast|slow]
#   fast  — quick sanity: SERVER_CPU=2, multi-stream {10,100}, multi-fanout {M=10,S=10},
#            DURATION=15, REPEATS=1, 1 pod-bump allowed
#   slow  — full matrix: SERVER_CPU ∈ {8,16}, multi-stream {10,100,1000,10000},
#            multi-fanout {(10,100),(100,10),(1000,10)}, DURATION=30, REPEATS=3
#
# Prerequisites: cluster up (scripts/gke-up.sh), PROJECT set or in gcloud config.
# DS-rust only.
# Results → results/scaleout/<RUN_ID>/<cell>/rep<N>/{merged.json,samples.csv,verdict.txt}
#
# bash 3.2 compatible (macOS/GKE build nodes): no associative arrays, no ${!var}.
#
# NOTE: The helpers below (deploy_server, reset_sidecar_samples, collect_sidecar,
# clean_jobs, run_fleet_and_coordinator, compute_server_cpu_pct, headroom_verdict,
# run_cell) are duplicated from scripts/gke-rawpower.sh (Phase 1).  Once Phase 1 and
# Phase 2 are both stable, extract these into scripts/lib-fleet.sh and source it from
# both runners.  Do NOT merge/edit gke-rawpower.sh in the meantime.
set -euo pipefail

PROFILE="${1:-fast}"
case "$PROFILE" in
  fast|slow) ;;
  *) echo "ERROR: unknown profile '${PROFILE}' (supported: fast | slow)" >&2; exit 1 ;;
esac

# ── project / cluster ──────────────────────────────────────────────────────────
PROJECT="$(gcloud config get-value project 2>/dev/null)"
ZONE=europe-west1-b
CLUSTER=ds-bench
CTX="gke_${PROJECT}_${ZONE}_${CLUSTER}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ALL kubectl calls go through K() — scoped to the bench cluster+namespace only.
K() { kubectl --context "$CTX" -n ds-bench "$@"; }

# ── run identity ───────────────────────────────────────────────────────────────
RUN_ID="scaleout-${PROFILE}-$(date +%s)-$$"
# Stable base for STREAM names. RUN_ID is re-set per cell/rep/pods deep in the
# headroom loop (used only as the MinIO results prefix), so stream names must NOT
# use it — otherwise each cell's bench_cmd, built before that re-set, embeds the
# PREVIOUS cell's RUN_ID and produces malformed concatenated stream names.
SWEEP_RUN_ID="$RUN_ID"
RESULTS_ROOT="results/scaleout/${RUN_ID}"
mkdir -p "$RESULTS_ROOT"

TARGET="http://durable-streams:4438"
PROBE_HOSTPORT="durable-streams:4438"

# ── profile knobs ──────────────────────────────────────────────────────────────
if [ "$PROFILE" = "fast" ]; then
  SERVER_CPUS="2"
  DURATION=15
  REPEATS="${REPEATS:-1}"
  INIT_PARALLELISM="${PARALLELISM:-4}"
  MAX_PODS=16
  MAX_BUMPS="${MAX_BUMPS:-1}"
else
  # Single 8-core server: n2d-standard-8 cannot host 16 cores.  Matrix capped
  # under the known server-hang limit (~1024 concurrent conns on a small node):
  # multi-stream N ∈ {10,50,100,200} (×2 pods ≤ 400 conns), multi-fanout (M,S)
  # pairs with M×S ≤ 200 (×2 ≤ 400 subscriber conns).  See MS_COUNTS / MF_PAIRS.
  SERVER_CPUS="8"
  DURATION=25
  REPEATS="${REPEATS:-3}"
  INIT_PARALLELISM="${PARALLELISM:-4}"
  MAX_PODS=32
  MAX_BUMPS="${MAX_BUMPS:-8}"
fi

echo "=== gke-scaleout: profile=${PROFILE} run_id=${RUN_ID} ==="
echo "    SERVER_CPUS='${SERVER_CPUS}'  DURATION=${DURATION}  REPEATS=${REPEATS}"
echo "    INIT_PARALLELISM=${INIT_PARALLELISM}  MAX_PODS=${MAX_PODS}"
echo ""

# ── Step 0: metrics-poller ConfigMap (idempotent, must exist before server) ───
echo "--- creating metrics-poller ConfigMap..."
K create configmap metrics-poller \
  --from-file=poller.sh=deploy/metrics/poller.sh \
  --dry-run=client -o yaml | K apply -f -

# ── helpers (duplicated from gke-rawpower.sh — see refactor note at top) ──────

# deploy_server SERVER_CPU
#   Applies durable-streams.yaml with envsubst (no tier flags — local-durable is
#   fine for stream-count scale-out).  Waits for deployment available + 3× HTTP probe.
deploy_server() {
  local cpu="$1"
  export PROJECT SERVER_CPU="$cpu"

  echo "    deploying durable-streams server: cpu=${cpu}..."
  envsubst '${PROJECT} ${SERVER_CPU}' < gke/durable-streams.yaml | K apply -f -

  K wait --for=condition=available deploy/durable-streams --timeout=300s
  echo "    server available."

  # 3× consecutive HTTP readiness probe from a client node
  echo "    probing server (need 3 consecutive HTTP answers)..."
  K run "server-probe-$$" --rm --attach --restart=Never --image=curlimages/curl:latest \
    --overrides='{"spec":{"nodeSelector":{"role":"client"}}}' --command -- \
    /bin/sh -c "ok=0; for i in \$(seq 1 90); do code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://${PROBE_HOSTPORT}/ 2>/dev/null); case \"\$code\" in 2??|3??|4??|5??) ok=\$((ok+1));; *) ok=0;; esac; if [ \"\$ok\" -ge 3 ]; then echo \"server ready (HTTP \$code, 3x)\"; exit 0; fi; sleep 1; done; echo 'server never ready'; exit 1" </dev/null \
    && echo "    probe ok" \
    || echo "    WARN: probe pod non-zero (kubectl --rm attach is flaky); continuing"
}

# reset_sidecar_samples
reset_sidecar_samples() {
  local pod
  pod="$( { K get pod -l app=durable-streams -o name 2>/dev/null || true; } | head -1 | sed 's|pod/||')"
  if [ -n "$pod" ]; then
    echo "    resetting samples.csv on pod ${pod}..."
    K exec "$pod" -c metrics -- sh -c 'echo "ts_ms,rss_bytes,cpu_ticks" > /metrics/samples.csv' \
      || true
  fi
}

# collect_sidecar DEST_DIR
collect_sidecar() {
  local dest="$1"
  local pod
  pod="$( { K get pod -l app=durable-streams -o name 2>/dev/null || true; } | head -1 | sed 's|pod/||')"
  if [ -n "$pod" ]; then
    K cp "ds-bench/${pod}:/metrics/samples.csv" "${dest}/samples.csv" -c metrics \
      && echo "    saved samples.csv → ${dest}/samples.csv" \
      || echo "    WARN: could not copy samples.csv"
  else
    echo "    WARN: no durable-streams pod found for sidecar collection"
  fi
}

# clean_jobs — delete bench-fleet + bench-coordinator synchronously
clean_jobs() {
  K delete job bench-fleet bench-coordinator --ignore-not-found --wait=true >/dev/null 2>&1 || true
  for _ in $(seq 1 45); do
    j=$( { K get jobs bench-fleet bench-coordinator --no-headers 2>/dev/null || true; } | wc -l | tr -d ' ')
    p=$( { K get pods -l 'job-name in (bench-fleet,bench-coordinator)' --no-headers 2>/dev/null || true; } | wc -l | tr -d ' ')
    if [ "$j" = "0" ] && [ "$p" = "0" ]; then break; fi
    sleep 2
  done
}

# run_fleet_and_coordinator — expects: RUN_ID PARALLELISM BENCH_CMD OUT_PREFIX MERGE_CMD
run_fleet_and_coordinator() {
  export PROJECT RUN_ID PARALLELISM BENCH_CMD OUT_PREFIX MERGE_CMD

  clean_jobs

  echo "    launching fleet (${PARALLELISM} pods)..."
  envsubst '${PROJECT} ${RUN_ID} ${PARALLELISM} ${BENCH_CMD} ${OUT_PREFIX}' \
    < gke/bench-job.yaml | K apply -f -
  # Tolerant: a hung server makes some pods fail → the Job never reaches
  # `complete`. Wait for complete OR failed, then proceed — the coordinator
  # merges whatever HDRs the surviving pods uploaded (partial but real data),
  # instead of aborting the whole matrix under `set -e`.
  K wait --for=condition=complete job/bench-fleet --timeout="${FLEET_TIMEOUT:-180}s" 2>/dev/null \
    || K wait --for=condition=failed job/bench-fleet --timeout=5s 2>/dev/null \
    || true
  echo "    fleet pods: $(K get pods -l job-name=bench-fleet --no-headers 2>/dev/null | awk '{print $3}' | sort | uniq -c | tr '\n' ' ')"
  echo "    fleet done. Pod placement:"
  K get pods -l job-name=bench-fleet -o wide

  echo "    launching coordinator..."
  K delete job bench-coordinator --ignore-not-found --wait=true >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    c=$( { K get job bench-coordinator --no-headers 2>/dev/null || true; } | wc -l | tr -d ' ')
    if [ "$c" = "0" ]; then break; fi
    sleep 2
  done
  envsubst '${PROJECT} ${RUN_ID} ${MERGE_CMD}' < gke/coordinator-job.yaml | K apply -f -
  # Tolerant: if the fleet all-errored (server hung) there are no HDRs to merge
  # and the coordinator may never `complete` — don't abort the whole matrix.
  K wait --for=condition=complete job/bench-coordinator --timeout="${COORD_TIMEOUT:-90}s" 2>/dev/null \
    || K wait --for=condition=failed job/bench-coordinator --timeout=5s 2>/dev/null \
    || true
}

# compute_server_cpu_pct SAMPLES_CSV
#   Reads samples.csv (ts_ms,rss_bytes,cpu_ticks), computes:
#     cpu_pct = (Δcpu_ticks / CLK_TCK) / Δelapsed_s × 100
#   CLK_TCK = 100 (Linux default; getconf CLK_TCK inside the container).
#   Returns a value like "73.4" (percent of a single core), or "0" on error.
compute_server_cpu_pct() {
  local csv="$1"
  awk -F',' '
    NR==1 { next }               # skip header
    NR==2 { t0=$1; c0=$3; next } # first data row
    {
      t1=$1; c1=$3
    }
    END {
      if (t1=="" || t0==t1) { print "0"; exit }
      elapsed_s = (t1 - t0) / 1000.0
      delta_ticks = c1 - c0
      clk_tck = 100
      pct = (delta_ticks / clk_tck) / elapsed_s * 100
      printf "%.1f\n", pct
    }
  ' "$csv"
}

# headroom_verdict SAMPLES_CSV SERVER_CPU_CORES
#   Prints "server_bound" or "server_headroom".
#   Threshold: server must consume > 90% × SERVER_CPU_CORES × 100% to be bound.
headroom_verdict() {
  local csv="$1"
  local cpu_cores="$2"
  local pct threshold
  pct="$(compute_server_cpu_pct "$csv")"
  # threshold = 90% of full CPU allocation (in single-core-pct units)
  threshold=$(awk -v c="$cpu_cores" 'BEGIN { printf "%.0f", c * 100 * 0.9 }')
  awk -v pct="$pct" -v thr="$threshold" 'BEGIN {
    if (pct+0 >= thr+0) { print "server_bound" } else { print "server_headroom" }
  }'
}

# run_cell CELL_NAME BENCH_CMD OUT_PREFIX MERGE_CMD SERVER_CPU_CORES
#   Runs one matrix cell with the headroom-guard loop (bumps PARALLELISM until
#   server is saturated or MAX_PODS cap is hit).  Writes per-repeat artifacts:
#   merged.json, samples.csv, verdict.txt.
run_cell() {
  local cell_name="$1"
  local bench_cmd="$2"
  local out_prefix="$3"
  local merge_cmd="$4"
  local cpu_cores="$5"

  echo ""
  echo "=== cell: ${cell_name}  cpu=${cpu_cores}  repeats=${REPEATS} ==="

  local repeat
  for repeat in $(seq 1 "$REPEATS"); do
    local cell_dir="${RESULTS_ROOT}/${cell_name}/rep${repeat}"
    mkdir -p "$cell_dir"

    local pods="$INIT_PARALLELISM"
    local bumps=0
    local verdict="client_capped"   # pessimistic default

    while true; do
      echo "  [rep ${repeat}/${REPEATS}] parallelism=${pods}"

      # Per-run unique ID (cell + repeat + attempt)
      RUN_ID="scaleout-${PROFILE}-$(date +%s)-$$-${cell_name}-r${repeat}-p${pods}"
      export PARALLELISM="$pods"
      BENCH_CMD="$bench_cmd"
      OUT_PREFIX="$out_prefix"
      MERGE_CMD="$merge_cmd"

      reset_sidecar_samples
      run_fleet_and_coordinator

      # Collect artifacts
      K logs job/bench-coordinator > "${cell_dir}/merged.json"
      echo "    saved merged.json → ${cell_dir}/merged.json"
      collect_sidecar "$cell_dir"

      # Headroom guard — v is iteration-local; verdict is the final loop outcome
      local v="server_bound"
      if [ -f "${cell_dir}/samples.csv" ]; then
        local cpu_pct
        cpu_pct="$(compute_server_cpu_pct "${cell_dir}/samples.csv")"
        v="$(headroom_verdict "${cell_dir}/samples.csv" "$cpu_cores")"
        echo "    server CPU%=${cpu_pct}  iter_verdict=${v}  (threshold=$(awk -v c="$cpu_cores" 'BEGIN{printf "%.0f", c*100*0.9}')%)"
      else
        echo "    WARN: no samples.csv — assuming server_bound (cannot verify headroom)"
      fi

      if [ "$v" = "server_bound" ]; then
        verdict="server_bound"
        break
      fi

      # Not server-bound: can we bump?
      if [ "$bumps" -ge "$MAX_BUMPS" ]; then
        echo "    MAX_BUMPS (${MAX_BUMPS}) reached without saturating server → client_capped"
        verdict="client_capped"
        break
      fi
      local new_pods
      new_pods=$((pods * 2))
      if [ "$new_pods" -gt "$MAX_PODS" ]; then
        echo "    MAX_PODS (${MAX_PODS}) reached without saturating server → client_capped"
        verdict="client_capped"
        break
      fi

      echo "    server not yet saturated → doubling pods: ${pods} → ${new_pods}"
      bumps=$((bumps + 1))
      pods="$new_pods"
    done

    # Write verdict AFTER the loop so we persist the FINAL outcome (server_bound or
    # client_capped), not the intermediate per-iteration headroom check (server_headroom).
    {
      echo "cell=${cell_name}"
      echo "repeat=${repeat}"
      echo "parallelism=${pods}"
      echo "server_cpu_cores=${cpu_cores}"
      if [ -f "${cell_dir}/samples.csv" ]; then
        echo "server_cpu_pct=$(compute_server_cpu_pct "${cell_dir}/samples.csv")"
      fi
      echo "verdict=${verdict}"
    } > "${cell_dir}/verdict.txt"
    echo "    written verdict.txt: ${verdict}"

    echo "  rep ${repeat}/${REPEATS} final verdict: ${verdict}  parallelism=${pods}"
  done
}

# ── matrix ─────────────────────────────────────────────────────────────────────
# Two workload families per profile:
#   1. multi-stream writes   — sweep over stream counts N
#   2. multi-fanout          — sweep over (M streams × S subscribers) pairs
#
# Server: local-durable (no --tier flags needed for scale-out characterisation).

for SERVER_CPU in $SERVER_CPUS; do

  echo ""
  echo "════════════════════════════════════════════════════════════════════════"
  echo "=== deploying server: SERVER_CPU=${SERVER_CPU} ==="
  echo "════════════════════════════════════════════════════════════════════════"
  deploy_server "$SERVER_CPU"

  # ── multi-stream write cells ──────────────────────────────────────────────────
  if [ "$PROFILE" = "fast" ]; then
    MS_COUNTS="10 100"
  else
    # capped under server-hang limit: max N=200 × 2 pods = 400 conns ≤ 512
    MS_COUNTS="10 50 100 200"
  fi

  for N in $MS_COUNTS; do
    cell="ms-cpu${SERVER_CPU}-n${N}"
    bench_cmd="multi-stream --target http://durable-streams:4438 --api-style durable --streams ${N} --duration-secs ${DURATION} --payload-bytes 256"
    out_prefix="ms"
    merge_cmd="ds-bench hdr-merge --hdr-dir /merge --results-dir /merge --label-prefix ms-"
    run_cell "$cell" "$bench_cmd" "$out_prefix" "$merge_cmd" "$SERVER_CPU"
  done

  # ── multi-fanout cells ────────────────────────────────────────────────────────
  if [ "$PROFILE" = "fast" ]; then
    # single pair: M=10, S=10
    MF_PAIRS="10:10"
  else
    # capped under server-hang limit: M×S ≤ 200 subscriber conns × 2 pods ≤ 400
    # pairs: (M=10,S=10), (M=20,S=10), (M=10,S=20)
    MF_PAIRS="10:10 20:10 10:20"
  fi

  for ms_pair in $MF_PAIRS; do
    M="${ms_pair%%:*}"
    S="${ms_pair##*:}"
    cell="multi-fanout-cpu${SERVER_CPU}-m${M}-s${S}"
    bench_cmd="multi-fanout --target http://durable-streams:4438 --api-style durable --streams ${M} --subscribers-per-stream ${S} --writer-rate 50 --duration-secs ${DURATION}"
    out_prefix="multi-fanout"
    merge_cmd="ds-bench hdr-merge --hdr-dir /merge --results-dir /merge --label-prefix multi-fanout-"
    run_cell "$cell" "$bench_cmd" "$out_prefix" "$merge_cmd" "$SERVER_CPU"
  done

done

echo ""
echo "=== gke-scaleout ${PROFILE} complete. Results in ${RESULTS_ROOT}/ ==="
