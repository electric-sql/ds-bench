#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# run-one.sh PHASE CLUSTER ZONE — run ONE phase on its OWN dedicated cluster,
# end to end: cluster-up → run → render → teardown. Designed to run several in
# parallel (one phase per cluster) by giving each a distinct CLUSTER + ZONE.
#
#   PHASE   = rawpower | scaleout | sustained
#   CLUSTER = GKE cluster name (e.g. ds-bench-p1)   [remote only]
#   ZONE    = GKE zone (e.g. europe-west1-d)        [remote only]
#
# All matrix/knob env vars (SERVER_CPUS, READ_SIZES, MS_COUNTS, MAX_BUMPS,
# CLIENT_NODES, REPEATS, SKIP_SPLICE, …) are read from the environment by the
# runner/cluster-up, so export them before calling this.
#
# Captures the runner's OWN PRINTED results dir (never `ls -t`, which races when
# phases run concurrently) and renders to docs/cloud-<phase>-report.md.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
PHASE="${1:?usage: run-one.sh PHASE CLUSTER ZONE}"
export CLUSTER="${2:?need CLUSTER}" ZONE="${3:?need ZONE}" DS_TARGET=remote
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$REPO"

case "$PHASE" in
  rawpower)  RUNNER=scripts/gke-rawpower.sh;  RENDER=scripts/render-rawpower.py;  SUB=rawpower ;;
  scaleout)  RUNNER=scripts/gke-scaleout.sh;  RENDER=scripts/render-scaleout.py;  SUB=scaleout ;;
  sustained) RUNNER=scripts/gke-sustained.sh; RENDER=scripts/render-sustained.py; SUB=sustained ;;
  *) echo "unknown PHASE '$PHASE' (rawpower|scaleout|sustained)" >&2; exit 2 ;;
esac
LOG="/tmp/run-${PHASE}-${CLUSTER}.log"
say() { echo "[${PHASE}/${CLUSTER}@${ZONE}] $*"; }

say "cluster-up (CLIENT_NODES=${CLIENT_NODES:-2})..."
if ! scripts/cluster-up.sh >> "$LOG" 2>&1; then
  say "cluster-up FAILED — tail:"; tail -6 "$LOG"
  scripts/cluster-down.sh >> "$LOG" 2>&1 || true   # clean any partial
  exit 1
fi

say "running..."
if [ "$PHASE" = "sustained" ]; then
  "$RUNNER" durable sustained ${SUSTAINED_N:-10 50 100 200} >> "$LOG" 2>&1; rc=$?
else
  "$RUNNER" "${PROFILE:-slow}" >> "$LOG" 2>&1; rc=$?
fi

# The runner prints "Results in results/<sub>/<run-id>/" — capture THAT, not ls -t.
RESDIR=$(grep -oE "results/${SUB}/[A-Za-z0-9._-]+" "$LOG" | tail -1)
say "run rc=${rc}  results=${RESDIR:-<none>}"
mkdir -p docs
if [ -n "$RESDIR" ] && [ -d "$RESDIR" ]; then
  python3 "$RENDER" "$RESDIR" > "docs/cloud-${PHASE}-report.md" 2>&1 \
    && say "rendered docs/cloud-${PHASE}-report.md ($(find "$RESDIR" -name merged.json | wc -l | tr -d ' ') cells)"
fi

say "teardown..."
scripts/cluster-down.sh >> "$LOG" 2>&1 && say "torn down ✓" || say "TEARDOWN FAILED — check $LOG"
say "DONE"
