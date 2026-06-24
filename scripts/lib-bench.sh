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
  # SERVER_EXTRA_ARGS (env) is prepended to any per-call flags so a comparison can
  # add server flags (e.g. "--wal --wal-sync strict --wal-fsync-events 1") to every
  # deploy without threading them through each runner. xargs normalizes whitespace
  # so the empty case stays empty (preserves the no-injection fast path).
  local extra_args; extra_args="$(echo "${SERVER_EXTRA_ARGS:-} ${*:-}" | xargs)"
  export SERVER_CPU="$cpu"

  # ── ursula variant ─────────────────────────────────────────────────────────
  # A different server (separate manifest, no --wal/--splice/--tier injection).
  # Matched node + cgroup budget (SERVER_CPU/SERVER_MEM) for a fair comparison.
  # Caller sets SERVER_KIND=ursula and TARGET/API_STYLE/PROBE_HOSTPORT=ursula:4437.
  if [ "${SERVER_KIND:-durable}" = "ursula" ]; then
    echo "    deploying ursula server: cpu=${cpu} mem=${SERVER_MEM} (${DS_TARGET})..."
    envsubst "${MANIFEST_VARS} \${SERVER_CPU} \${PROJECT}" < gke/ursula.yaml | K apply -f -
    K rollout status deploy/ursula --timeout=600s
    echo "    ursula available."
    echo "    probing ursula (need 3 consecutive HTTP answers)..."
    K run "ursula-probe-$$" --rm --attach --restart=Never --image=curlimages/curl:latest \
      --overrides="{\"spec\":{\"nodeSelector\":${NODESEL_CLIENT}}}" --command -- \
      /bin/sh -c "ok=0; for i in \$(seq 1 90); do code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://${PROBE_HOSTPORT}/ 2>/dev/null); case \"\$code\" in 2??|3??|4??|5??) ok=\$((ok+1));; *) ok=0;; esac; if [ \"\$ok\" -ge 3 ]; then echo \"ursula ready (HTTP \$code, 3x)\"; exit 0; fi; sleep 1; done; echo 'ursula never ready'; exit 1" </dev/null \
      && echo "    probe ok" \
      || echo "    WARN: probe pod non-zero (kubectl --rm attach is flaky); continuing"
    return 0
  fi

  echo "    deploying durable-streams server: cpu=${cpu} extra='${extra_args}' (${DS_TARGET})..."

  if [ -z "$extra_args" ]; then
    envsubst "${MANIFEST_VARS} \${SERVER_CPU}" < gke/durable-streams.yaml | K apply -f -

  elif echo "$extra_args" | grep -q -- "--tier local"; then
    local tmp_tier
    tmp_tier="$(mktemp /tmp/ds-tier-XXXXXX)"
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
    tmp_inject="$(mktemp /tmp/ds-inject-XXXXXX)"
    for flag in $extra_args; do
      printf '            - "%s"\n' "$flag" >> "$tmp_inject"
    done
    envsubst "${MANIFEST_VARS} \${SERVER_CPU}" < gke/durable-streams.yaml \
      | sed "/--tier-allow-http/r ${tmp_inject}" \
      | K apply -f -
    rm -f "$tmp_inject"
  fi

  K wait --for=condition=available deploy/durable-streams --timeout=600s
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

# server_label — pod selector for the server under test (durable-streams | ursula),
# so the metrics sidecar helpers find the right pod regardless of SERVER_KIND.
server_label() { [ "${SERVER_KIND:-durable}" = "ursula" ] && echo "app=ursula" || echo "app=durable-streams"; }

# reset_sidecar_samples — truncate the server sidecar's samples.csv before a cell.
reset_sidecar_samples() {
  local pod
  pod="$( { K get pod -l "$(server_label)" -o name 2>/dev/null || true; } | head -1 | sed 's|pod/||')"
  if [ -n "$pod" ]; then
    echo "    resetting samples.csv on pod ${pod}..."
    K exec "$pod" -c metrics -- sh -c 'echo "ts_ms,rss_bytes,cpu_ticks,write_bytes" > /metrics/samples.csv' || true
  fi
}

# collect_sidecar DEST_DIR — copy the server sidecar's samples.csv out.
collect_sidecar() {
  local dest="$1"
  local pod
  pod="$( { K get pod -l "$(server_label)" -o name 2>/dev/null || true; } | head -1 | sed 's|pod/||')"
  if [ -n "$pod" ]; then
    K cp "ds-bench/${pod}:/metrics/samples.csv" "${dest}/samples.csv" -c metrics \
      && echo "    saved samples.csv → ${dest}/samples.csv" \
      || echo "    WARN: could not copy samples.csv"
  else
    echo "    WARN: no server pod found for sidecar collection"
  fi
}

# server_calibration_key — calibration key for the CURRENTLY RUNNING server pod:
# <image-digest12>-<machine>-cpu<cpus>-mem<mem>. Machine is "kind" when unset (local).
server_calibration_key() {
  local img machine
  img="$(K get pod -l "$(server_label)" -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' 2>/dev/null)"
  machine="${SERVER_MACHINE:-kind}"
  python3 "${REPO_ROOT}/scripts/pins.py" key --image "$img" \
    --machine "$machine" --cpu "$SERVER_CPUS" --mem "$SERVER_MEM"
}

# clean_jobs — delete bench-fleet + bench-coordinator synchronously.
clean_jobs() {
  # --cascade=foreground: block until the Jobs' PODS are gone too (default background
  # cascade deletes the Job object but reaps pods async -> they linger into the next
  # rung, which reused the fixed job names -> stale-pod log reads + "already exists").
  K delete job bench-fleet bench-coordinator --ignore-not-found --cascade=foreground --wait=true >/dev/null 2>&1 || true
  for _ in $(seq 1 45); do
    j=$( { K get jobs bench-fleet bench-coordinator --no-headers 2>/dev/null || true; } | wc -l | tr -d ' ')
    p=$( { K get pods -l 'job-name in (bench-fleet,bench-coordinator)' --no-headers 2>/dev/null || true; } | wc -l | tr -d ' ')
    if [ "$j" = "0" ] && [ "$p" = "0" ]; then break; fi
    sleep 2
  done
}

# _capture_choke_diagnostics — when a fleet didn't fully Complete, log WHY (to stderr,
# i.e. the run log) so a "creation_choke" is backed by a concrete cause. Distinguishes:
#   * server CRASH/OOM  -> server pod restarts>0 / lastTerminated reason OOMKilled|Error
#   * server CRASHLOOP   -> state=waiting reason=CrashLoopBackOff (e.g. s2lite)
#   * TIMEOUT (heavy)    -> server Running, 0 restarts; client pod still Running/slow
# plus a non-Completed client pod's last log lines (the actual client-side error).
_capture_choke_diagnostics() {
  echo "    ── choke diagnostics ──────────────────────────────────────────" >&2
  K get pods -l 'app in (durable-streams,ursula,s2lite)' -o jsonpath='{range .items[*]}      SERVER {.metadata.name} phase={.status.phase} restarts={.status.containerStatuses[0].restartCount} state={.status.containerStatuses[0].state} lastTerminated={.status.containerStatuses[0].lastState.terminated.reason}:{.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}{end}' 2>/dev/null >&2 || true
  local fp; fp="$(K get pods -l job-name=bench-fleet --no-headers 2>/dev/null | awk '$3!="Completed"{print $1; exit}')"
  if [ -n "$fp" ]; then
    echo "      CLIENT pod $fp ($(K get pod "$fp" -o jsonpath='{.status.phase}' 2>/dev/null)) — log tail:" >&2
    K logs "$fp" --tail=12 2>&1 | sed 's/^/        /' >&2 || true
  fi
  echo "    ───────────────────────────────────────────────────────────────" >&2
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
  # If any fleet pod did NOT Complete, the cell will choke — capture WHY now (the
  # server pod's crash/OOM/restart state + a failed client pod's log tail), so the
  # generic "creation_choke" label is backed by a concrete reason in the run log.
  if K get pods -l job-name=bench-fleet --no-headers 2>/dev/null | awk '$3!="Completed"{f=1} END{exit !f}'; then
    _capture_choke_diagnostics
  fi

  echo "    launching coordinator..."
  K delete job bench-coordinator --ignore-not-found --cascade=foreground --wait=true >/dev/null 2>&1 || true
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

# fetch_coordinator_merged DEST — pull coordinator stdout into DEST. Retries while
# the pod is still ContainerCreating (kubectl logs returns BadRequest then). Never
# fatal: on persistent failure writes an error marker so `set -e` can't abort.
fetch_coordinator_merged() {
  local dest="$1" i out cpod
  for i in $(seq 1 30); do
    # Read the NEWEST coordinator pod specifically (not `job/bench-coordinator`,
    # which can match a lingering previous-rung pod and return STALE merged data).
    cpod="$(K get pods -l job-name=bench-coordinator --sort-by=.metadata.creationTimestamp \
            -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)"
    if [ -n "$cpod" ] && out="$(K logs "$cpod" 2>/dev/null)" && [ -n "$out" ]; then
      printf '%s\n' "$out" > "$dest"
      return 0
    fi
    sleep 2
  done
  echo '{"error":"coordinator logs unavailable after retries"}' > "$dest"
  echo "    WARN: coordinator logs unavailable after retries → wrote error marker"
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

# compute_server_mem_mb SAMPLES_CSV — prints "PEAK_MB DRIFT_MB" from rss_bytes (col 2).
#   peak  = max(rss)               (high-water mark, MiB)
#   drift = rss(last) - rss(first) (growth over the window, MiB; may be negative)
# Sidecar-instrumented for durable only; "0 0" when there are no data rows.
compute_server_mem_mb() {
  awk -F',' '
    NR==1 { next }
    NR==2 { r0=$2; rl=$2; peak=$2; next }
    { rl=$2; if ($2>peak) peak=$2 }
    END {
      if (r0=="") { print "0 0"; exit }
      drift = (rl - r0) / 1048576
      if (drift > -0.5 && drift < 0.5) drift = 0
      printf "%.0f %.0f\n", peak/1048576, drift
    }' "$1"
}

# run_cell CELL_NAME BENCH_CMD OUT_PREFIX MERGE_CMD SERVER_CPU_CORES
#   Dispatches per MODE (default: measure):
#     calibrate — bumps parallelism to the saturation knee and pins the result via
#                 pins.py (REPEATS forced to 1; safe to re-run).
#     measure   — resolves the pinned pod-count for this cell/key, then runs
#                 REPEATS-fixed reps (fail-fast if no pin; set REUSE_CALIBRATION=latest
#                 to fall back to the most-recent matching calibration).
#   Collects merged.json/samples.csv/verdict.txt per rep under
#   ${RESULTS_ROOT}/<cell>/rep<N>/.
_run_cell_one() {
  local cell_name="$1" bench_cmd="$2" out_prefix="$3" merge_cmd="$4" pods="$5" repeat="$6" cell_dir="$7"
  RUN_ID="${SWEEP_RUN_ID}-${cell_name}-r${repeat}-p${pods}"
  export PARALLELISM="$pods"
  BENCH_CMD="$bench_cmd"; OUT_PREFIX="$out_prefix"; MERGE_CMD="$merge_cmd"
  { reset_sidecar_samples
    run_fleet_and_coordinator
    fetch_coordinator_merged "${cell_dir}/merged.json"
    collect_sidecar "$cell_dir"
  } >&2
  local cpu_pct="0"
  if [ -f "${cell_dir}/samples.csv" ]; then
    cpu_pct="$(compute_server_cpu_pct "${cell_dir}/samples.csv")"
  fi
  local thr
  thr="$(python3 "${REPO_ROOT}/scripts/saturation.py" --merged "${cell_dir}/merged.json" \
          --prev-thr 0 --cpu "$cpu_pct" --cores 1 2>/dev/null | awk '{print $2}')"
  echo "${cpu_pct} ${thr:-0}"
}

# _run_cell_calibrate — bump until saturation_check says cpu/plateau (or caps), pin the knee.
_run_cell_calibrate() {
  local cell_name="$1" bench_cmd="$2" out_prefix="$3" merge_cmd="$4" cpu_cores="$5" cell_dir="$6" repeat="$7"
  local pods="$INIT_PARALLELISM" prev_pods=0 prev_thr=0 bumps=0
  local reason="max_pods" saturated="false" pin_pods="$pods" pin_thr=0
  while true; do
    echo "  [calibrate ${cell_name}] parallelism=${pods}"
    read -r cpu_pct thr < <(_run_cell_one "$cell_name" "$bench_cmd" "$out_prefix" "$merge_cmd" "$pods" "$repeat" "$cell_dir")
    # Classify via saturation.py's CLI (prints "<reason> <thr>"); take the reason.
    # Uses shell-expanded $REPO_ROOT (not os.environ — phase scripts don't export it).
    local cls
    cls="$(python3 "${REPO_ROOT}/scripts/saturation.py" --merged "${cell_dir}/merged.json" \
      --prev-thr "$prev_thr" --cpu "$cpu_pct" --cores "$cpu_cores" | awk '{print $1}')"
    echo "    cpu%=${cpu_pct} thr=${thr} class=${cls}"
    if [ "$cls" = "cpu" ]; then
      reason="cpu"; saturated="true"; pin_pods="$pods"; pin_thr="$thr"; break
    elif [ "$cls" = "plateau" ]; then
      reason="plateau"; saturated="true"; pin_pods="$prev_pods"; pin_thr="$prev_thr"; break
    fi
    if [ "$bumps" -ge "$MAX_BUMPS" ] || [ $((pods * 2)) -gt "$MAX_PODS" ]; then
      reason="max_pods"; saturated="false"; pin_pods="$pods"; pin_thr="$thr"; break
    fi
    prev_pods="$pods"; prev_thr="$thr"; bumps=$((bumps + 1)); pods=$((pods * 2))
  done
  local key; key="$(server_calibration_key)"
  python3 "${REPO_ROOT}/scripts/pins.py" set "$key" "$cell_name" "$pin_pods" \
    --reason "$reason" --saturated "$saturated" --ops "${pin_thr%.*}" \
    --image "$(K get pod -l "$(server_label)" -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' 2>/dev/null)" \
    --machine "${SERVER_MACHINE:-kind}" --cpu "$SERVER_CPUS" --mem "$SERVER_MEM"
  { echo "cell=${cell_name}"; echo "mode=calibrate"; echo "parallelism=${pin_pods}";
    echo "server_cpu_cores=${cpu_cores}"; echo "reason=${reason}"; echo "saturated=${saturated}";
    echo "calibration_key=${key}"; } > "${cell_dir}/verdict.txt"
  echo "  calibrated ${cell_name}: pods=${pin_pods} reason=${reason} saturated=${saturated} → ${key}"
}

# _run_cell_measure — resolve the pin for this cell (own key, else REUSE=latest, else
# fail fast), run REPEATS-fixed at the pinned pods, record provenance.
_run_cell_measure() {
  local cell_name="$1" bench_cmd="$2" out_prefix="$3" merge_cmd="$4" cpu_cores="$5" cell_dir="$6" repeat="$7"
  local key used_key pin_pods matched="true"
  key="$(server_calibration_key)"
  if pin_pods="$(python3 "${REPO_ROOT}/scripts/pins.py" get "$key" "$cell_name" 2>/dev/null)"; then
    used_key="$key"
  elif [ "${REUSE_CALIBRATION:-}" = "latest" ]; then
    used_key="$(python3 "${REPO_ROOT}/scripts/pins.py" latest "${SERVER_MACHINE:-kind}" "$SERVER_CPUS" "$SERVER_MEM" 2>/dev/null)" \
      || { echo "ERROR: REUSE_CALIBRATION=latest but no calibration for machine=${SERVER_MACHINE:-kind} cpu=${SERVER_CPUS} mem=${SERVER_MEM}" >&2; exit 1; }
    pin_pods="$(python3 "${REPO_ROOT}/scripts/pins.py" get "$used_key" "$cell_name" 2>/dev/null)" \
      || { echo "ERROR: reused calibration ${used_key} has no cell ${cell_name}" >&2; exit 1; }
    matched="false"
    echo "    REUSE: pinning from ${used_key} (image mismatch vs ${key})"
  else
    echo "ERROR: no calibration for ${key} cell ${cell_name}; run MODE=calibrate or set REUSE_CALIBRATION=latest" >&2
    exit 1
  fi

  echo "  [measure ${cell_name}] pinned parallelism=${pin_pods} (matched=${matched})"
  local cpu_pct thr
  read -r cpu_pct thr < <(_run_cell_one "$cell_name" "$bench_cmd" "$out_prefix" "$merge_cmd" "$pin_pods" "$repeat" "$cell_dir")
  { echo "cell=${cell_name}"; echo "mode=measure"; echo "parallelism=${pin_pods}";
    echo "server_cpu_cores=${cpu_cores}"; echo "server_cpu_pct=${cpu_pct}";
    echo "calibration_key=${used_key}"; echo "running_key=${key}";
    echo "calibration_matched=${matched}"; } > "${cell_dir}/verdict.txt"
  echo "  measured ${cell_name}: pods=${pin_pods} cpu%=${cpu_pct} thr=${thr} matched=${matched}"
}

run_cell() {
  local cell_name="$1" bench_cmd="$2" out_prefix="$3" merge_cmd="$4" cpu_cores="$5"
  local MODE="${MODE:-measure}"
  if [ "$MODE" = "calibrate" ]; then REPEATS=1; fi

  echo ""
  echo "=== cell: ${cell_name}  cpu=${cpu_cores}  repeats=${REPEATS} ==="

  local repeat
  for repeat in $(seq 1 "$REPEATS"); do
    local cell_dir="${RESULTS_ROOT}/${cell_name}/rep${repeat}"
    mkdir -p "$cell_dir"

    if [ "$MODE" = "calibrate" ]; then
      _run_cell_calibrate "$cell_name" "$bench_cmd" "$out_prefix" "$merge_cmd" "$cpu_cores" "$cell_dir" "$repeat"
    else
      _run_cell_measure "$cell_name" "$bench_cmd" "$out_prefix" "$merge_cmd" "$cpu_cores" "$cell_dir" "$repeat"
    fi
  done
}

# reset_state <mode> — clear server state between cells WITHOUT recreating the
# cluster. Pod restart wipes the emptyDir (+ the wipe-data initContainer guarantees
# the data-dir is empty even on NVMe). s2 keeps state in MinIO, so its bucket is
# emptied too. Deployment/bucket names: wal=durable-streams, ursula=ursula,
# s2=s2lite (bucket s2-bench). RESET_DRYRUN=1 echoes commands instead of running
# them (for tests).
# _wait_server_http <hostport> — block until the server returns 3 CONSECUTIVE HTTP
# responses through its Service (any 2xx–5xx = listener serving), so a fleet never
# races a freshly-restarted server whose old pod is still terminating / whose
# Service endpoints haven't re-pointed yet (the GKE creation_choke). rollout status
# only proves TCP readiness; this proves the server actually serves. Best-effort:
# the throwaway curl pod's --rm/--attach is flaky on exit, but its in-pod loop still
# performs the readiness WAIT regardless of the attach exit code.
_wait_server_http() {
  local hostport="$1"
  K run "reset-probe-$$-${RANDOM}" --rm --attach --restart=Never \
    --image=curlimages/curl:latest --overrides="{\"spec\":{\"nodeSelector\":${NODESEL_CLIENT}}}" --command -- \
    /bin/sh -c "ok=0; for i in \$(seq 1 60); do code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://${hostport}/ 2>/dev/null); case \"\$code\" in 2??|3??|4??|5??) ok=\$((ok+1));; *) ok=0;; esac; [ \"\$ok\" -ge 3 ] && exit 0; sleep 1; done; exit 1" </dev/null >/dev/null 2>&1 || true
}

reset_state() {
  local mode="$1" run
  if [ "${RESET_DRYRUN:-0}" = "1" ]; then run="echo"; else run=""; fi
  case "$mode" in
    s2)
      # mc's alias lives in the minio pod's ~/.mc config; set it inline (as the
      # rest of the harness does) so the rm works in a fresh exec session.
      $run kubectl --context "$KCTX" -n ds-bench exec deploy/minio -- sh -c \
        'mc alias set local http://localhost:9000 minioadmin minioadmin >/dev/null 2>&1; mc rm --recursive --force local/s2-bench/ 2>/dev/null; true' || true
      $run kubectl --context "$KCTX" -n ds-bench rollout restart deploy/s2lite
      if [ -z "$run" ]; then kubectl --context "$KCTX" -n ds-bench rollout status deploy/s2lite --timeout=120s; _wait_server_http s2lite:80; fi
      ;;
    wal)
      $run kubectl --context "$KCTX" -n ds-bench rollout restart deploy/durable-streams
      if [ -z "$run" ]; then kubectl --context "$KCTX" -n ds-bench rollout status deploy/durable-streams --timeout=120s; _wait_server_http durable-streams:4438; fi
      ;;
    ursula)
      $run kubectl --context "$KCTX" -n ds-bench rollout restart deploy/ursula
      if [ -z "$run" ]; then kubectl --context "$KCTX" -n ds-bench rollout status deploy/ursula --timeout=120s; _wait_server_http ursula:4437; fi
      ;;
    *) echo "reset_state: unknown mode '$mode'" >&2; return 2 ;;
  esac
}

# deploy_mode <mode> — deploy ONE server for a persistent-cluster cell run and set
# the addressing globals (T_TARGET/T_API/T_NS) the walker's measure_pods consumes.
# Mirrors gke-bench.sh deploy_system's per-mode switch, but WITHOUT the per-cell
# `K delete` (the cluster persists; reset_state clears state between cells). Modes:
#   wal    -> durable-streams, --durability wal --wal-shards N --splice-appends
#   ursula -> ursula (URSULA_WAL backend from env; cold tier -> MinIO `ursula`)
#   s2     -> s2lite (cold tier -> MinIO `s2-bench`)
deploy_mode() {
  local mode="$1"
  case "$mode" in
    wal)
      # The (WAL-only) reference server needs NO durability flag: it always WALs,
      # auto-picks wal-shards = core count on a fresh data-dir (reset_state wipes it
      # each cell), and defaults tail-cache to 0 (off) on Linux. So the default is
      # empty. WAL_SERVER_ARGS injects server knobs to SWEEP (e.g. "--wal-shards 8"
      # or "--tail-cache-bytes 65536") when finding the optimal config.
      local args="${WAL_SERVER_ARGS:-}"
      SERVER_KIND=durable SERVER_EXTRA_ARGS="$args" PROBE_HOSTPORT="durable-streams:4438" \
        deploy_server "$SERVER_CPU" >&2 || return 1
      T_TARGET="http://durable-streams:4438"; T_API="durable"; T_NS="" ;;
    ursula)
      SERVER_KIND=ursula URSULA_WAL="${URSULA_WAL:-disk}" PROBE_HOSTPORT="ursula:4437" \
        deploy_server "$SERVER_CPU" >&2 || return 1
      T_TARGET="http://ursula:4437"; T_API="ursula"; T_NS="--bucket benchmark" ;;
    s2)
      K apply -f gke/s2lite.yaml >&2 && K rollout status deploy/s2lite --timeout=600s >&2 || return 1
      T_TARGET="http://s2lite:80"; T_API="s2"; T_NS="--basin benchmark" ;;
    *) echo "deploy_mode: unknown mode '$mode'" >&2; return 1 ;;
  esac
  export T_TARGET T_API T_NS
}

# server_image_digest <mode> [config_args] — echo a 12-char digest of the deployed
# server image (+ the config's server args, so a changed image OR a changed config
# re-runs that cell; see cells.status_of). Deployment per mode: wal=durable-streams,
# ursula=ursula, s2=s2lite.
server_image_digest() {
  local dep; case "$1" in wal) dep=durable-streams;; ursula) dep=ursula;; s2) dep=s2lite;; esac
  local img; img="$(K get "deploy/$dep" -o jsonpath='{.spec.template.spec.containers[0].image}')"
  printf '%s\n%s\n' "$img" "${2:-}" | sha256sum | cut -c1-12
}
