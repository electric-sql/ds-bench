#!/usr/bin/env bash
# End-to-end Phase-2a harness: kind cluster lifecycle + all 4 workloads.
# Stands up kind cluster, deploys MinIO + durable-streams, then runs each
# workload through the 2-pod Indexed fleet → coordinator merge pipeline.
# Teardown + prior kubectl context restore happen in a trap on EXIT.
# Compatible with bash 3.2 (macOS default): no associative arrays used.
set -euo pipefail

CLUSTER=ds-bench
CTX=kind-${CLUSTER}
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRIOR_CTX="$(kubectl config current-context 2>/dev/null || true)"

cleanup() {
  echo ""
  echo "=== teardown: deleting kind cluster ${CLUSTER} ==="
  kind delete cluster --name "${CLUSTER}" >/dev/null 2>&1 || true
  if [ -n "${PRIOR_CTX}" ]; then
    kubectl config use-context "${PRIOR_CTX}" >/dev/null 2>&1 || true
    echo "=== restored kubectl context: ${PRIOR_CTX} ==="
  fi
}
trap cleanup EXIT

cd "${REPO_ROOT}"

# ---------------------------------------------------------------------------
# Per-workload command strings — returned by get_wl_cmd()
# ---------------------------------------------------------------------------
get_wl_cmd() {
  local wl="$1"
  case "$wl" in
    multi-stream)
      echo "multi-stream --target http://durable-streams:4438 --api-style durable --streams 20 --duration-secs 15 --payload-bytes 256"
      ;;
    fan-out)
      echo "fan-out --target http://durable-streams:4438 --api-style durable --subscribers 50 --writer-rate 50 --duration-secs 15 --payload-bytes 256"
      ;;
    catch-up)
      echo "catch-up --target http://durable-streams:4438 --api-style durable --clients 50 --pre-events 500 --event-bytes 256"
      ;;
    mixed)
      echo "mixed --target http://durable-streams:4438 --api-style durable --streams 4 --readers 4 --subscribers 4 --duration-secs 15"
      ;;
    *)
      echo "ERROR: unknown workload: $wl" >&2
      exit 1
      ;;
  esac
}

WORKLOADS="multi-stream fan-out catch-up mixed"

# ---------------------------------------------------------------------------
# 1. Cluster creation (idempotent: delete first if exists)
# ---------------------------------------------------------------------------
echo "=== deleting any existing kind cluster '${CLUSTER}' (idempotent) ==="
kind delete cluster --name "${CLUSTER}" >/dev/null 2>&1 || true

echo "=== creating kind cluster ==="
kind create cluster --config k8s/kind-cluster.yaml

# ---------------------------------------------------------------------------
# 2. Build images
# ---------------------------------------------------------------------------
echo "=== building ds-bench image ==="
docker compose build bench

echo "=== building durable-streams image ==="
docker build -f dockerfiles/durable-streams.Dockerfile -t ds-bench/durable-streams:dev ../durable-streams

echo "=== loading images into kind ==="
kind load docker-image ds-bench/ds-bench:dev --name "${CLUSTER}"
kind load docker-image ds-bench/durable-streams:dev --name "${CLUSTER}"

# ---------------------------------------------------------------------------
# 3. Deploy MinIO + PVC; wait for minio-init; deploy durable-streams
# ---------------------------------------------------------------------------
echo "=== applying MinIO + PVC ==="
kubectl --context "${CTX}" apply -f k8s/minio.yaml -f k8s/results-pvc.yaml

echo "=== waiting for minio-init ==="
kubectl --context "${CTX}" wait --for=condition=complete job/minio-init --timeout=300s

echo "=== applying durable-streams ==="
kubectl --context "${CTX}" apply -f k8s/durable-streams.yaml

echo "=== waiting for durable-streams deployment ==="
kubectl --context "${CTX}" wait --for=condition=available deploy/durable-streams --timeout=300s

# ---------------------------------------------------------------------------
# Helper: generate per-workload coordinator Job manifest (stdout).
# For mixed, runs three label-scoped hdr-merge calls; for all others runs
# one unfiltered merge (original behaviour).
# ---------------------------------------------------------------------------
make_coordinator_job() {
  local wl="$1"
  local cmd
  if [ "$wl" = "mixed" ]; then
    cmd='echo "== merged (mixed / write) ==" && ds-bench hdr-merge --hdr-dir /results --label-prefix mixed-write && echo "== merged (mixed / fanout) ==" && ds-bench hdr-merge --hdr-dir /results --label-prefix mixed-fanout && echo "== merged (mixed / read) ==" && ds-bench hdr-merge --hdr-dir /results --label-prefix mixed-read'
  else
    cmd='ds-bench hdr-merge --hdr-dir /results --results-dir /results'
  fi
  printf '%s\n' "apiVersion: batch/v1
kind: Job
metadata:
  name: bench-coordinator
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: coordinator
          image: ds-bench/ds-bench:dev
          imagePullPolicy: Never
          command: [\"/bin/sh\", \"-c\"]
          args:
            - \"${cmd}\"
          volumeMounts:
            - { name: results, mountPath: /results }
      volumes:
        - name: results
          persistentVolumeClaim:
            claimName: bench-results"
}

# ---------------------------------------------------------------------------
# Helper: generate per-workload bench Job manifest (stdout)
# ---------------------------------------------------------------------------
make_bench_job() {
  local wl="$1"
  local cmd
  cmd="$(get_wl_cmd "$wl")"
  # Use printf to avoid heredoc quoting issues with $JOB_COMPLETION_INDEX
  printf '%s\n' "apiVersion: batch/v1
kind: Job
metadata:
  name: bench-fleet
spec:
  completions: 2
  parallelism: 2
  completionMode: Indexed
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: ds-bench
          image: ds-bench/ds-bench:dev
          imagePullPolicy: Never
          env:
            - { name: DS_BENCH_HDR_OUT, value: /results }
          command: [\"/bin/sh\", \"-c\"]
          args:
            - >
              DS_BENCH_INSTANCE=\"\$JOB_COMPLETION_INDEX\"
              ds-bench ${cmd}
              > /results/${wl}-\${JOB_COMPLETION_INDEX}.json
          volumeMounts:
            - { name: results, mountPath: /results }
          resources:
            requests:
              memory: \"128Mi\"
              cpu: \"250m\"
            limits:
              memory: \"512Mi\"
      volumes:
        - name: results
          persistentVolumeClaim:
            claimName: bench-results"
}

# ---------------------------------------------------------------------------
# Helper: clear /results on the PVC via a short-lived pod
# Aborts the harness (exit 1) if the cleaner pod fails to create, ends in
# Failed phase, or does not reach Succeeded within 60 s — prevents a
# subsequent workload from merging stale files from the prior run.
# ---------------------------------------------------------------------------
clear_results_pvc() {
  echo "  clearing /results PVC..."
  # Delete any leftover cleaner pod
  kubectl --context "${CTX}" delete pod pvc-cleaner --ignore-not-found >/dev/null 2>&1 || true

  # Capture exit status; do NOT swallow failures with || true
  if ! kubectl --context "${CTX}" run pvc-cleaner --image=busybox:1.36 \
    --restart=Never \
    --overrides='{"spec":{"volumes":[{"name":"results","persistentVolumeClaim":{"claimName":"bench-results"}}],"containers":[{"name":"pvc-cleaner","image":"busybox:1.36","command":["/bin/sh","-c","rm -f /results/* && echo cleared"],"volumeMounts":[{"name":"results","mountPath":"/results"}]}]}}' \
    >/dev/null 2>&1; then
    echo "  ERROR: failed to create pvc-cleaner pod — aborting to avoid stale results" >&2
    exit 1
  fi

  # Wait for the cleaner pod to finish (up to 60s)
  local i=0
  local phase="Pending"
  while [ $i -lt 60 ]; do
    phase="$(kubectl --context "${CTX}" get pod pvc-cleaner -o jsonpath='{.status.phase}' 2>/dev/null || echo "Missing")"
    if [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ] || [ "$phase" = "Missing" ]; then
      break
    fi
    sleep 1
    i=$((i+1))
  done

  # Evaluate outcome — only Succeeded is safe to proceed
  if [ "$phase" = "Succeeded" ]; then
    kubectl --context "${CTX}" delete pod pvc-cleaner --ignore-not-found >/dev/null 2>&1 || true
    echo "  /results cleared."
  elif [ "$phase" = "Failed" ]; then
    echo "  ERROR: pvc-cleaner pod ended in Failed phase — aborting to avoid stale results" >&2
    kubectl --context "${CTX}" logs pvc-cleaner 2>/dev/null || true
    kubectl --context "${CTX}" delete pod pvc-cleaner --ignore-not-found >/dev/null 2>&1 || true
    exit 1
  else
    # Missing or still running after 60 s
    echo "  ERROR: pvc-cleaner did not reach Succeeded within 60 s (phase=${phase}) — aborting to avoid stale results" >&2
    kubectl --context "${CTX}" delete pod pvc-cleaner --ignore-not-found >/dev/null 2>&1 || true
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# 4. Loop over workloads
# ---------------------------------------------------------------------------
FAILED_WLS=""
PASSED_WLS=""

for WL in $WORKLOADS; do
  echo ""
  echo "========================================================"
  echo "=== workload: ${WL} ==="
  echo "========================================================"

  # Clean up prior Jobs
  echo "  deleting prior bench-fleet + bench-coordinator jobs..."
  kubectl --context "${CTX}" delete job bench-fleet --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context "${CTX}" delete job bench-coordinator --ignore-not-found >/dev/null 2>&1 || true

  # Wait for pods to terminate (best-effort)
  local_timeout=60
  elapsed=0
  while [ $elapsed -lt $local_timeout ]; do
    remaining_fleet=$(kubectl --context "${CTX}" get pods -l job-name=bench-fleet --no-headers 2>/dev/null | wc -l | tr -d ' ')
    remaining_coord=$(kubectl --context "${CTX}" get pods -l job-name=bench-coordinator --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$remaining_fleet" = "0" ] && [ "$remaining_coord" = "0" ]; then
      break
    fi
    sleep 2
    elapsed=$((elapsed+2))
  done
  if [ $elapsed -ge $local_timeout ]; then
    echo "  WARNING: prior pods did not fully terminate within ${local_timeout}s — proceeding anyway" >&2
  fi

  # Clear PVC results
  clear_results_pvc

  # Apply per-workload bench Job
  echo "  applying bench-fleet job for ${WL}..."
  make_bench_job "${WL}" | kubectl --context "${CTX}" apply -f -

  echo "  waiting for bench-fleet to complete (timeout 600s)..."
  if ! kubectl --context "${CTX}" wait --for=condition=complete job/bench-fleet --timeout=600s; then
    echo "  ERROR: bench-fleet did not complete for ${WL}"
    echo "  --- bench-fleet pod logs ---"
    kubectl --context "${CTX}" logs -l job-name=bench-fleet --prefix=true 2>/dev/null || true
    FAILED_WLS="${FAILED_WLS} ${WL}(fleet)"
    continue
  fi

  # Apply per-workload coordinator Job
  echo "  applying bench-coordinator job for ${WL}..."
  make_coordinator_job "${WL}" | kubectl --context "${CTX}" apply -f -

  echo "  waiting for bench-coordinator to complete (timeout=180s)..."
  if ! kubectl --context "${CTX}" wait --for=condition=complete job/bench-coordinator --timeout=180s; then
    echo "  ERROR: bench-coordinator did not complete for ${WL}"
    echo "  --- coordinator pod logs ---"
    kubectl --context "${CTX}" logs job/bench-coordinator 2>/dev/null || true
    FAILED_WLS="${FAILED_WLS} ${WL}(coordinator)"
    continue
  fi

  MERGED="$(kubectl --context "${CTX}" logs job/bench-coordinator 2>/dev/null || true)"
  PASSED_WLS="${PASSED_WLS} ${WL}"

  echo ""
  if [ "$WL" = "mixed" ]; then
    # mixed coordinator already prints labeled sections (write/fanout/read)
    echo "${MERGED}"
  else
    echo "== merged (${WL}) =="
    echo "${MERGED}"
  fi
done

# ---------------------------------------------------------------------------
# 5. Summary
# ---------------------------------------------------------------------------
echo ""
echo "========================================================"
echo "=== PHASE-2a SUMMARY ==="
echo "========================================================"
if [ -n "${PASSED_WLS}" ]; then
  echo "PASSED:${PASSED_WLS}"
fi
if [ -n "${FAILED_WLS}" ]; then
  echo "FAILED:${FAILED_WLS}"
fi

echo ""
echo "=== kind-run.sh complete ==="
# trap fires here → kind delete + context restore
