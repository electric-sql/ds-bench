#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# lib-bench.sh — shared benchmark engine for the DS-rust suite.
#
# Sourced by the phase runners (gke-rawpower.sh = phase 1, gke-scaleout.sh =
# phase 2, gke-sustained.sh = phase 3). It is PURE definitions + target
# selection — sourcing it touches no cluster. It in turn sources target-env.sh
# (DS_TARGET=local kind | remote GKE) and defines K() + the deploy / fleet /
# coordinator / headroom / collect engine.
#
# A runner's job shrinks to: set its config + its matrix, then call the engine.
#   Config a runner must set before calling run_cell:
#     SERVER_CPUS DURATION REPEATS INIT_PARALLELISM MAX_PODS MAX_BUMPS
#     SWEEP_RUN_ID RESULTS_ROOT TARGET API_STYLE [PROBE_HOSTPORT]
#
# Contracts:
#   SWEEP_RUN_ID — stable per-run id. Matrix bench_cmds MUST name streams
#                  "${cell}-${SWEEP_RUN_ID}". run_cell re-sets $RUN_ID per attempt
#                  (the MinIO results prefix) so streams must NOT use $RUN_ID, or
#                  each cell would inherit the previous cell's id (malformed names).
#   RESULTS_ROOT — per-cell rep dirs (merged.json / samples.csv / verdict.txt) land
#                  under ${RESULTS_ROOT}/<cell>/rep<N>/.
# ─────────────────────────────────────────────────────────────────────────────

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/target-env.sh
. "${_LIB_DIR}/target-env.sh"

PROBE_HOSTPORT="${PROBE_HOSTPORT:-durable-streams:4438}"

# ALL kubectl calls go through K() — scoped to the selected context + ds-bench ns.
K() { kubectl --context "$KCTX" -n ds-bench "$@"; }

# ensure_metrics_configmap — poller.sh ConfigMap (idempotent; must exist before
# the server, whose metrics sidecar mounts it).
ensure_metrics_configmap() {
  echo "--- ensuring metrics-poller ConfigMap..."
  K create configmap metrics-poller \
    --from-file=poller.sh=deploy/metrics/poller.sh \
    --dry-run=client -o yaml | K apply -f -
}

# ── deploy_server SERVER_CPU [extra_args...] ─────────────────────────────────
#   Applies durable-streams.yaml (envsubst MANIFEST_VARS + SERVER_CPU), optionally
#   patching server args. Two injection modes selected from extra_args:
#     "--tier local"  -> REPLACE the S3 tier block with a local cold-tier block.
#     other flags     -> APPEND each as a YAML list item after "--tier-allow-http".
#   Both use `sed r <tmpfile>` / range-delete (BSD-sed + GNU-sed safe).
deploy_server() {
  local cpu="$1"; shift
  local extra_args="${*:-}"
  export SERVER_CPU="$cpu"

  echo "    deploying durable-streams server: cpu=${cpu} extra='${extra_args}' (${DS_TARGET})..."

  if [ -z "$extra_args" ]; then
    envsubst "${MANIFEST_VARS} \${SERVER_CPU}" < gke/durable-streams.yaml | K apply -f -

  elif echo "$extra_args" | grep -q -- "--tier local"; then
    local tmp_tier
    tmp_tier="$(mktemp /tmp/ds-tier-XXXXXX.txt)"
    printf '            - "--tier"\n'               >> "$tmp_tier"
    printf '            - "local"\n'                >> "$tmp_tier"
    printf '            - "--tier-local-dir"\n'     >> "$tmp_tier"
    printf '            - "/data/cold"\n'           >> "$tmp_tier"
    printf '            - "--tier-segment-bytes"\n' >> "$tmp_tier"
    printf '            - "1048576"\n'              >> "$tmp_tier"
    envsubst "${MANIFEST_VARS} \${SERVER_CPU}" < gke/durable-streams.yaml \
      | sed \
          -e '/- "--tier"$/,/- "--tier-allow-http"$/d' \
          -e "/- \"\/data\"/r ${tmp_tier}" \
      | K apply -f -
    rm -f "$tmp_tier"

  else
    local tmp_inject
    tmp_inject="$(mktemp /tmp/ds-inject-XXXXXX.txt)"
    for flag in $extra_args; do
      printf '            - "%s"\n' "$flag" >> "$tmp_inject"
    done
    envsubst "${MANIFEST_VARS} \${SERVER_CPU}" < gke/durable-streams.yaml \
      | sed "/--tier-allow-http/r ${tmp_inject}" \
      | K apply -f -
    rm -f "$tmp_inject"
  fi

  K wait --for=condition=available deploy/durable-streams --timeout=300s
  echo "    server available."

  # 3× consecutive HTTP readiness probe. nodeSelector via ${NODESEL_CLIENT} so it
  # schedules on a client node (remote) or anywhere (single-node kind, local).
  echo "    probing server (need 3 consecutive HTTP answers)..."
  K run "server-probe-$$" --rm --attach --restart=Never --image=curlimages/curl:latest \
    --overrides="{\"spec\":{\"nodeSelector\":${NODESEL_CLIENT}}}" --command -- \
    /bin/sh -c "ok=0; for i in \$(seq 1 90); do code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://${PROBE_HOSTPORT}/ 2>/dev/null); case \"\$code\" in 2??|3??|4??|5??) ok=\$((ok+1));; *) ok=0;; esac; if [ \"\$ok\" -ge 3 ]; then echo \"server ready (HTTP \$code, 3x)\"; exit 0; fi; sleep 1; done; echo 'server never ready'; exit 1" </dev/null \
    && echo "    probe ok" \
    || echo "    WARN: probe pod non-zero (kubectl --rm attach is flaky); continuing"
}

# reset_sidecar_samples — truncate the server sidecar's samples.csv before a cell.
reset_sidecar_samples() {
  local pod
  pod="$( { K get pod -l app=durable-streams -o name 2>/dev/null || true; } | head -1 | sed 's|pod/||')"
  if [ -n "$pod" ]; then
    echo "    resetting samples.csv on pod ${pod}..."
    K exec "$pod" -c metrics -- sh -c 'echo "ts_ms,rss_bytes,cpu_ticks,write_bytes" > /metrics/samples.csv' || true
  fi
}

# collect_sidecar DEST_DIR — copy the server sidecar's samples.csv out.
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

# clean_jobs — delete bench-fleet + bench-coordinator synchronously.
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
  export RUN_ID PARALLELISM BENCH_CMD OUT_PREFIX MERGE_CMD

  clean_jobs

  echo "    launching fleet (${PARALLELISM} pods)..."
  envsubst "${MANIFEST_VARS} \${RUN_ID} \${PARALLELISM} \${BENCH_CMD} \${OUT_PREFIX}" \
    < gke/bench-job.yaml | K apply -f -
  # Tolerant: a hung/saturated server makes some pods fail → the Job never reaches
  # `complete`. Wait for complete OR failed, then proceed — the coordinator merges
  # whatever HDRs the surviving pods uploaded, instead of aborting under `set -e`.
  K wait --for=condition=complete job/bench-fleet --timeout="${FLEET_TIMEOUT:-180}s" 2>/dev/null \
    || K wait --for=condition=failed job/bench-fleet --timeout=5s 2>/dev/null \
    || true
  echo "    fleet pods: $(K get pods -l job-name=bench-fleet --no-headers 2>/dev/null | awk '{print $3}' | sort | uniq -c | tr '\n' ' ')"
  K get pods -l job-name=bench-fleet -o wide 2>/dev/null || true

  echo "    launching coordinator..."
  K delete job bench-coordinator --ignore-not-found --wait=true >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    c=$( { K get job bench-coordinator --no-headers 2>/dev/null || true; } | wc -l | tr -d ' ')
    if [ "$c" = "0" ]; then break; fi
    sleep 2
  done
  envsubst "${MANIFEST_VARS} \${RUN_ID} \${MERGE_CMD}" < gke/coordinator-job.yaml | K apply -f -
  # Tolerant: if the fleet all-errored there are no HDRs to merge and the
  # coordinator may never `complete` — don't abort the whole matrix.
  K wait --for=condition=complete job/bench-coordinator --timeout="${COORD_TIMEOUT:-90}s" 2>/dev/null \
    || K wait --for=condition=failed job/bench-coordinator --timeout=5s 2>/dev/null \
    || true
}

# compute_server_cpu_pct SAMPLES_CSV — cpu_pct = (Δticks/CLK_TCK)/Δs ×100. CLK_TCK=100.
compute_server_cpu_pct() {
  local csv="$1"
  awk -F',' '
    NR==1 { next }
    NR==2 { t0=$1; c0=$3; next }
    { t1=$1; c1=$3 }
    END {
      if (t1=="" || t0==t1) { print "0"; exit }
      elapsed_s = (t1 - t0) / 1000.0
      delta_ticks = c1 - c0
      clk_tck = 100
      printf "%.1f\n", (delta_ticks / clk_tck) / elapsed_s * 100
    }
  ' "$csv"
}

# headroom_verdict SAMPLES_CSV SERVER_CPU_CORES — "server_bound" if CPU ≥ 90%×cores.
headroom_verdict() {
  local csv="$1" cpu_cores="$2" pct threshold
  pct="$(compute_server_cpu_pct "$csv")"
  threshold=$(awk -v c="$cpu_cores" 'BEGIN { printf "%.0f", c * 100 * 0.9 }')
  awk -v pct="$pct" -v thr="$threshold" 'BEGIN {
    if (pct+0 >= thr+0) { print "server_bound" } else { print "server_headroom" }
  }'
}

# run_cell CELL_NAME BENCH_CMD OUT_PREFIX MERGE_CMD SERVER_CPU_CORES
#   Runs one matrix cell with the headroom-guard loop (bumps PARALLELISM until the
#   server saturates or MAX_PODS/MAX_BUMPS). Collects merged.json/samples.csv/verdict.txt
#   per REPEAT under ${RESULTS_ROOT}/<cell>/rep<N>/.
run_cell() {
  local cell_name="$1" bench_cmd="$2" out_prefix="$3" merge_cmd="$4" cpu_cores="$5"

  echo ""
  echo "=== cell: ${cell_name}  cpu=${cpu_cores}  repeats=${REPEATS} ==="

  local repeat
  for repeat in $(seq 1 "$REPEATS"); do
    local cell_dir="${RESULTS_ROOT}/${cell_name}/rep${repeat}"
    mkdir -p "$cell_dir"

    local pods="$INIT_PARALLELISM"
    local bumps=0
    local verdict="client_capped"

    while true; do
      echo "  [rep ${repeat}/${REPEATS}] parallelism=${pods}"

      # Per-attempt id = MinIO results prefix. Streams use $SWEEP_RUN_ID (stable),
      # NOT this, so a cell never inherits the previous cell's id.
      RUN_ID="${SWEEP_RUN_ID}-${cell_name}-r${repeat}-p${pods}"
      export PARALLELISM="$pods"
      BENCH_CMD="$bench_cmd"
      OUT_PREFIX="$out_prefix"
      MERGE_CMD="$merge_cmd"

      reset_sidecar_samples
      run_fleet_and_coordinator

      K logs job/bench-coordinator > "${cell_dir}/merged.json"
      echo "    saved merged.json → ${cell_dir}/merged.json"
      collect_sidecar "$cell_dir"

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
        verdict="server_bound"; break
      fi
      if [ "$bumps" -ge "$MAX_BUMPS" ]; then
        echo "    MAX_BUMPS (${MAX_BUMPS}) reached without saturating server → client_capped"
        verdict="client_capped"; break
      fi
      local new_pods=$((pods * 2))
      if [ "$new_pods" -gt "$MAX_PODS" ]; then
        echo "    MAX_PODS (${MAX_PODS}) reached without saturating server → client_capped"
        verdict="client_capped"; break
      fi
      echo "    server not yet saturated → doubling pods: ${pods} → ${new_pods}"
      bumps=$((bumps + 1)); pods="$new_pods"
    done

    # Persist the FINAL outcome (server_bound | client_capped), not the per-iter check.
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
    echo "  rep ${repeat}/${REPEATS} final verdict: ${verdict}  parallelism=${pods}"
  done
}
