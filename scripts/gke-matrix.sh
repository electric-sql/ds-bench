#!/usr/bin/env bash
# Phase 2b.2 BOUNDED matrix runner. Drives the single-node head-to-head plus one
# saturation sweep, ONE server-under-test at a time (deploy/scale-up -> run all
# its workloads -> scale-down so only one heavy server bills at a time). Every
# merged JSON is saved to results-gke/.
#
# COST DISCIPLINE (the cluster bills per hour):
#   * single-node matrix only (DS-rust / ursula / S2; DS-node SKIPPED — library,
#     no entrypoint/env-config/S3-tier — see gke/ds-node-SKIPPED.md).
#   * one saturation sweep (durable multi-stream, client parallelism 2->4->8) —
#     NOT the full payload x subscriber x system cartesian (deferred, noted).
#   * each server scaled to 0 replicas when it's not the system-under-test.
#
# Every kubectl is scoped to the dedicated context + namespace. bash 3.2 safe.
set -euo pipefail

PROJECT="$(gcloud config get-value project 2>/dev/null)"
ZONE=europe-west1-b
CLUSTER=ds-bench
CTX="gke_${PROJECT}_${ZONE}_${CLUSTER}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
K() { kubectl --context "$CTX" -n ds-bench "$@"; }

OUT_DIR="$REPO_ROOT/results-gke"
mkdir -p "$OUT_DIR"

# Baseline fleet pods for the head-to-head (identical across systems for fairness).
BASE_PODS="${BASE_PODS:-4}"

# --- deploy helpers: bring ONE server up, scale the others to 0 ---
ensure_only() {
  # $1 = system to keep up (durable|ursula|s2)
  local keep="$1"
  echo "=== server topology: keeping '$keep' up, scaling others to 0 ==="
  # ensure the wanted server exists + scaled to 1
  case "$keep" in
    durable) envsubst '${PROJECT}' < gke/durable-streams.yaml | K apply -f - >/dev/null
             K scale deploy/durable-streams --replicas=1 ;;
    ursula)  envsubst '${PROJECT}' < gke/ursula.yaml | K apply -f - >/dev/null
             K scale deploy/ursula --replicas=1 ;;
    s2)      K apply -f gke/s2lite.yaml >/dev/null
             K scale deploy/s2lite --replicas=1 ;;
  esac
  # scale the others down (ignore if absent)
  for d in durable-streams ursula s2lite; do
    case "$keep:$d" in
      durable:durable-streams|ursula:ursula|s2:s2lite) : ;;
      *) K scale deploy/$d --replicas=0 >/dev/null 2>&1 || true ;;
    esac
  done
  case "$keep" in
    durable) K wait --for=condition=available deploy/durable-streams --timeout=300s ;;
    ursula)  K wait --for=condition=available deploy/ursula --timeout=300s ;;
    s2)      K wait --for=condition=available deploy/s2lite --timeout=300s ;;
  esac
}

# --- run one (system, workload, pods) and save the merged JSON(s) ---
# Captures gke-run.sh stdout, extracts the merged JSON object(s) printed by the
# coordinator, and writes results-gke/<tag>.json. For mixed, the coordinator
# prints three labeled JSON blocks; we split them into -write/-fanout/-read.
run_and_save() {
  local system="$1" workload="$2" pods="$3" tag="$4"
  echo ""
  echo "########## RUN: system=$system workload=$workload pods=$pods tag=$tag ##########"
  local log="$OUT_DIR/$tag.log"
  # gke-run.sh ensures the server itself is up (we already scaled it); the run
  # script's ensure step is idempotent and cheap.
  if ! GKE_RUN_SKIP_SERVER=1 ./scripts/gke-run.sh "$system" "$workload" "$pods" >"$log" 2>&1; then
    echo "  !! gke-run.sh failed for $tag (see $log)"; tail -5 "$log" || true; return 1
  fi
  # client-pod CPU headroom snapshot (so we know the generator isn't the bottleneck)
  K top pods -l job-name=bench-fleet --no-headers 2>/dev/null | sed 's/^/  client-pod cpu: /' || true

  if [ "$workload" = "mixed" ]; then
    # three labeled blocks: "== merged (mixed / write) ==" { ... } etc.
    for class in write fanout read; do
      awk -v c="$class" '
        $0 ~ "== merged \\(mixed / " c " \\) ==" {grab=1; next}
        grab && /^\{/ {inj=1}
        inj {print}
        inj && /^\}/ {exit}
      ' "$log" > "$OUT_DIR/$tag-$class.json" || true
      [ -s "$OUT_DIR/$tag-$class.json" ] && echo "  saved $tag-$class.json"
    done
  else
    # last JSON object in the log is the merged summary
    awk '/^\{/{buf=$0; cap=1; next} cap{buf=buf"\n"$0} /^\}/{if(cap){last=buf; cap=0}} END{print last}' "$log" > "$OUT_DIR/$tag.json" || true
    if [ -s "$OUT_DIR/$tag.json" ]; then echo "  saved $tag.json:"; cat "$OUT_DIR/$tag.json"; else echo "  (no JSON captured — see $log)"; fi
  fi
}

echo "############################################################"
echo "# Phase 2b.2 matrix  project=$PROJECT  base_pods=$BASE_PODS"
echo "# results -> $OUT_DIR"
echo "############################################################"

# ============================================================
# 1) DS-rust (durable) — all four workloads at baseline
# ============================================================
ensure_only durable
run_and_save durable multi-stream "$BASE_PODS" "durable-multi-stream"
run_and_save durable fan-out      "$BASE_PODS" "durable-fan-out"
run_and_save durable catch-up     "$BASE_PODS" "durable-catch-up"
run_and_save durable mixed        "$BASE_PODS" "durable-mixed"

# ------------------------------------------------------------
# 1b) SATURATION SWEEP — durable multi-stream, client parallelism 2->4->8.
#     Shows the server's throughput ceiling vs generator pods. (durable is
#     already up.) NOTE: this is the ONLY sweep — the full payload x subscriber
#     x system cartesian is deferred for cost (see report disclosures).
# ------------------------------------------------------------
for p in 2 4 8; do
  run_and_save durable multi-stream "$p" "sweep-durable-multi-stream-p$p"
done

# ============================================================
# 2) ursula (single node) — all four workloads at baseline
# ============================================================
ensure_only ursula
run_and_save ursula multi-stream "$BASE_PODS" "ursula-multi-stream"
run_and_save ursula fan-out      "$BASE_PODS" "ursula-fan-out"
run_and_save ursula catch-up     "$BASE_PODS" "ursula-catch-up"
run_and_save ursula mixed        "$BASE_PODS" "ursula-mixed"

# ============================================================
# 3) S2 Lite — multi-stream + fan-out only (excluded from catch-up/mixed)
# ============================================================
ensure_only s2
run_and_save s2 multi-stream "$BASE_PODS" "s2-multi-stream"
run_and_save s2 fan-out      "$BASE_PODS" "s2-fan-out"

echo ""
echo "=== matrix complete. merged JSONs in $OUT_DIR ==="
ls -1 "$OUT_DIR"/*.json 2>/dev/null || true
