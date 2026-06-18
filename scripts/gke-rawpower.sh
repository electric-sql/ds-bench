#!/usr/bin/env bash
# Phase 1 raw-power matrix runner: profile-driven, headroom-guarded.
# Drives reads / append / fan-out workloads across a CPU-budget matrix,
# scaling client pods until the SERVER is the bottleneck (uncapped).
#
# Usage: gke-rawpower.sh [fast|slow]
#   fast  — quick sanity: single CPU/conn point, 1 repeat, 1 bump allowed
#   slow  — full matrix: 4 CPU budgets × size/conn/body dims, 3 repeats,
#            unbounded bumps up to MAX_PODS
#
# Prerequisites: cluster up (scripts/gke-up.sh), PROJECT set or in gcloud config.
# DS-rust only. Results → results/rawpower/<RUN_ID>/<cell>/{merged.json,samples.csv,verdict.txt}
#
# bash 3.2 compatible (macOS/GKE build nodes): no associative arrays, no ${!var}.
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
RUN_ID="rawpower-${PROFILE}-$(date +%s)-$$"
RESULTS_ROOT="results/rawpower/${RUN_ID}"
mkdir -p "$RESULTS_ROOT"

TARGET="http://durable-streams:4438"
API_STYLE="durable"
PROBE_HOSTPORT="durable-streams:4438"

# ── profile knobs ──────────────────────────────────────────────────────────────
# fast: single CPU/dim point, 1 repeat, at most 1 pod-bump
# slow: full sweep, 3 repeats, bump until server_bound or MAX_PODS
if [ "$PROFILE" = "fast" ]; then
  SERVER_CPUS="2"
  DURATION=15
  REPEATS=1
  INIT_PARALLELISM="${PARALLELISM:-4}"
  MAX_PODS=16
  MAX_BUMPS=1
else
  SERVER_CPUS="2 4 8 16"
  DURATION=30
  REPEATS=3
  INIT_PARALLELISM="${PARALLELISM:-4}"
  MAX_PODS=32
  MAX_BUMPS=8
fi

echo "=== gke-rawpower: profile=${PROFILE} run_id=${RUN_ID} ==="
echo "    SERVER_CPUS='${SERVER_CPUS}'  DURATION=${DURATION}  REPEATS=${REPEATS}"
echo "    INIT_PARALLELISM=${INIT_PARALLELISM}  MAX_PODS=${MAX_PODS}"
echo ""

# ── Step 0: metrics-poller ConfigMap (idempotent, must exist before server) ───
echo "--- creating metrics-poller ConfigMap..."
K create configmap metrics-poller \
  --from-file=poller.sh=deploy/metrics/poller.sh \
  --dry-run=client -o yaml | K apply -f -

# ── helpers ────────────────────────────────────────────────────────────────────

# deploy_server SERVER_CPU [extra_args...]
#   Applies durable-streams.yaml with envsubst, optionally patching server args.
#
#   Two injection modes (selected automatically from extra_args):
#
#   1. "--splice-appends" (or any non-tier flag):
#      Appends one "- <flag>" YAML list item after the "--tier-allow-http" line.
#      Uses `sed r <tmpfile>` (file-read) which works on BOTH BSD sed (macOS) and
#      GNU sed — the broken `a\` + literal-\n approach only works on GNU sed.
#
#   2. "--tier local" (cold-tier variant):
#      Replaces the entire S3 tier block (--tier s3 through --tier-allow-http) with
#      a local cold-tier block: --tier local, --tier-local-dir /data/cold,
#      --tier-segment-bytes 1048576.  The two tier modes are mutually exclusive;
#      passing both s3 AND local flags to the server is an error.
deploy_server() {
  local cpu="$1"; shift
  local extra_args="${*:-}"   # space-separated flags, e.g. "--splice-appends" or "--tier local"
  export PROJECT SERVER_CPU="$cpu"

  echo "    deploying durable-streams server: cpu=${cpu} extra='${extra_args}'..."

  if [ -z "$extra_args" ]; then
    envsubst '${PROJECT} ${SERVER_CPU}' < gke/durable-streams.yaml | K apply -f -

  elif echo "$extra_args" | grep -q -- "--tier local"; then
    # Cold-tier variant: REPLACE the entire S3 tier block with a local cold-tier
    # block.  The S3 block in durable-streams.yaml is 9 lines spanning from
    # '- "--tier"' through '- "--tier-allow-http"'.  We use a sed range delete
    # (/start/,/end/d) which is valid on both BSD sed (macOS) and GNU sed.
    # The local tier block is then injected after the "- /data" (--data-dir value)
    # line using `sed r <tmpfile>` — also BSD+GNU safe.
    local tmp_tier
    tmp_tier="$(mktemp /tmp/ds-tier-XXXXXX.txt)"
    printf '            - "--tier"\n'             >> "$tmp_tier"
    printf '            - "local"\n'              >> "$tmp_tier"
    printf '            - "--tier-local-dir"\n'   >> "$tmp_tier"
    printf '            - "/data/cold"\n'         >> "$tmp_tier"
    printf '            - "--tier-segment-bytes"\n' >> "$tmp_tier"
    printf '            - "1048576"\n'            >> "$tmp_tier"

    envsubst '${PROJECT} ${SERVER_CPU}' < gke/durable-streams.yaml \
      | sed \
          -e '/- "--tier"$/,/- "--tier-allow-http"$/d' \
          -e "/- \"\/data\"/r ${tmp_tier}" \
      | K apply -f -
    rm -f "$tmp_tier"

  else
    # Generic extra flags: append each as a new YAML list item after
    # "--tier-allow-http" using `sed r <tmpfile>` (BSD + GNU safe).
    local tmp_inject
    tmp_inject="$(mktemp /tmp/ds-inject-XXXXXX.txt)"
    for flag in $extra_args; do
      printf '            - "%s"\n' "$flag" >> "$tmp_inject"
    done
    envsubst '${PROJECT} ${SERVER_CPU}' < gke/durable-streams.yaml \
      | sed "/--tier-allow-http/r ${tmp_inject}" \
      | K apply -f -
    rm -f "$tmp_inject"
  fi

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
  K wait --for=condition=complete job/bench-fleet --timeout=900s
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
  K wait --for=condition=complete job/bench-coordinator --timeout=300s
}

# compute_server_cpu_pct SAMPLES_CSV SERVER_CPU_CORES
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
#   Prints "server_bound" or "client_capped" or "server_headroom".
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

# run_cell CELL_NAME BENCH_CMD OUT_PREFIX MERGE_CMD SERVER_CPU_CORES [SERVER_EXTRA_ARGS]
#   Runs one matrix cell with the headroom-guard loop (bumps PARALLELISM until
#   server is saturated or MAX_PODS cap is hit).  Collects artifacts per REPEAT.
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
      RUN_ID="rawpower-${PROFILE}-$(date +%s)-$$-${cell_name}-r${repeat}-p${pods}"
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
# Cells are: workload type × configuration dimension × SERVER_CPU.
# Server args parametrized: standard cells use no extra args; splice/cold-tier
# cells pass extra flags via deploy_server which appends them via sed after the
# last existing arg ("--tier-allow-http") in the manifest.

for SERVER_CPU in $SERVER_CPUS; do

  echo ""
  echo "════════════════════════════════════════════════════════════════════════"
  echo "=== deploying server: SERVER_CPU=${SERVER_CPU} ==="
  echo "════════════════════════════════════════════════════════════════════════"
  deploy_server "$SERVER_CPU"

  # ── reads cells ─────────────────────────────────────────────────────────────
  if [ "$PROFILE" = "fast" ]; then
    READ_SIZES="1024"
    READ_CONNS="256"
  else
    READ_SIZES="1024 16384 1048576"
    READ_CONNS="16 64 256 1024"
  fi

  for read_size in $READ_SIZES; do
    for read_conn in $READ_CONNS; do
      cell="reads-cpu${SERVER_CPU}-size${read_size}-conn${read_conn}"
      # seed-bytes is fixed at 256 MiB so there is a large resident stream to
      # read repeatedly — using only read_size here would leave a single record
      # and measure request overhead rather than the sendfile/throughput path.
      bench_cmd="reads --target ${TARGET} --api-style ${API_STYLE} --stream ${cell}-${RUN_ID} --read-size-bytes ${read_size} --connections ${read_conn} --duration-secs ${DURATION} --seed-bytes 268435456"
      out_prefix="reads"
      merge_cmd="ds-bench hdr-merge --hdr-dir /merge --results-dir /merge --label-prefix reads-"
      run_cell "$cell" "$bench_cmd" "$out_prefix" "$merge_cmd" "$SERVER_CPU"
    done
  done

  # ── append cells ─────────────────────────────────────────────────────────────
  if [ "$PROFILE" = "fast" ]; then
    APPEND_CONNS="256"
    APPEND_BODIES="binary"
  else
    APPEND_CONNS="64 256"
    APPEND_BODIES="binary json-single json-array"
  fi

  for append_conn in $APPEND_CONNS; do
    for body_mode in $APPEND_BODIES; do
      # array-records flag only for json-array
      extra_bench_flags=""
      if [ "$body_mode" = "json-array" ]; then
        extra_bench_flags="--array-records 10"
      fi
      cell="append-cpu${SERVER_CPU}-conn${append_conn}-${body_mode}"
      bench_cmd="append --target ${TARGET} --api-style ${API_STYLE} --stream ${cell}-${RUN_ID} --connections ${append_conn} --payload-bytes 256 --duration-secs ${DURATION} --body-mode ${body_mode}${extra_bench_flags:+ $extra_bench_flags}"
      out_prefix="append"
      merge_cmd="ds-bench hdr-merge --hdr-dir /merge --results-dir /merge --label-prefix append-"
      run_cell "$cell" "$bench_cmd" "$out_prefix" "$merge_cmd" "$SERVER_CPU"
    done
  done

  # ── append splice variant (slow only): 1MB binary with --splice-appends ─────
  if [ "$PROFILE" = "slow" ]; then
    echo ""
    echo "=== deploying splice-appends server variant (cpu=${SERVER_CPU}) ==="
    deploy_server "$SERVER_CPU" "--splice-appends"

    cell="append-splice-cpu${SERVER_CPU}-conn256-binary-1m"
    bench_cmd="append --target ${TARGET} --api-style ${API_STYLE} --stream ${cell}-${RUN_ID} --connections 256 --payload-bytes 1048576 --duration-secs ${DURATION} --body-mode binary"
    out_prefix="append-splice"
    merge_cmd="ds-bench hdr-merge --hdr-dir /merge --results-dir /merge --label-prefix append-splice-"
    run_cell "$cell" "$bench_cmd" "$out_prefix" "$merge_cmd" "$SERVER_CPU"

    # Restore standard server before continuing
    echo "=== restoring standard server (cpu=${SERVER_CPU}) ==="
    deploy_server "$SERVER_CPU"
  fi

  # ── fan-out cells ─────────────────────────────────────────────────────────────
  if [ "$PROFILE" = "fast" ]; then
    FO_SUBS_LIST="256"
  else
    FO_SUBS_LIST="1 10 100 1000"
  fi

  for subs in $FO_SUBS_LIST; do
    cell="fanout-cpu${SERVER_CPU}-subs${subs}"
    bench_cmd="fan-out --target ${TARGET} --api-style ${API_STYLE} --stream ${cell}-${RUN_ID} --subscribers ${subs} --writer-rate 50 --duration-secs ${DURATION} --payload-bytes 256"
    out_prefix="fan-out"
    merge_cmd="ds-bench hdr-merge --hdr-dir /merge --results-dir /merge --label-prefix fanout-"
    run_cell "$cell" "$bench_cmd" "$out_prefix" "$merge_cmd" "$SERVER_CPU"
  done

  # ── cold-tier read cell (slow only): --tier local, seed > hot cap ─────────────
  # Server args: replace "--tier s3 ..." with "--tier local" via sed, then
  # deploy.  We redeploy from scratch with the cold-tier manifest patch.
  if [ "$PROFILE" = "slow" ]; then
    echo ""
    echo "=== deploying cold-tier server variant (cpu=${SERVER_CPU}) ==="
    deploy_server "$SERVER_CPU" "--tier local"

    # seed-bytes = 32 MiB = 32× the tier-segment-bytes (1 MiB) so multiple segments
    # seal + offload to cold storage and reads actually exercise the cold-tier path.
    cell="reads-cold-cpu${SERVER_CPU}-size1m-conn64"
    bench_cmd="reads --target ${TARGET} --api-style ${API_STYLE} --stream ${cell}-${RUN_ID} --read-size-bytes 1048576 --connections 64 --duration-secs ${DURATION} --seed-bytes 33554432"
    out_prefix="reads-cold"
    merge_cmd="ds-bench hdr-merge --hdr-dir /merge --results-dir /merge --label-prefix reads-cold-"
    run_cell "$cell" "$bench_cmd" "$out_prefix" "$merge_cmd" "$SERVER_CPU"

    # Restore standard server
    echo "=== restoring standard server (cpu=${SERVER_CPU}) ==="
    deploy_server "$SERVER_CPU"
  fi

done

echo ""
echo "=== gke-rawpower ${PROFILE} complete. Results in ${RESULTS_ROOT}/ ==="
