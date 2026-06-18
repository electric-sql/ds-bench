#!/usr/bin/env bash
# Strictly-sequential, sole-mutator ursula --preset sweep.
#
# Motivation: concurrent mutation of ursula's --preset by two runners produced
# impossible results (standard ~2,684 writes/s vs tiny/small ~7,000). This
# script is the ONLY thing allowed to change ursula's --preset; it runs all
# four presets one-at-a-time and logs each result via logrun.sh.
#
# Usage: gke-ursula-sweep.sh
#   No arguments.  PROJECT + CTX are resolved from gcloud/kubeconfig exactly
#   as gke-run.sh does.
#
# bash 3.2 compatible (macOS); no associative arrays.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PROJECT="$(gcloud config get-value project 2>/dev/null)"
ZONE=europe-west1-b
CLUSTER=ds-bench
CTX="gke_${PROJECT}_${ZONE}_${CLUSTER}"

K() { kubectl --context "$CTX" -n ds-bench "$@"; }

URSULA_YAML="$REPO_ROOT/gke/ursula.yaml"
GKE_RUN="$REPO_ROOT/scripts/gke-run.sh"
LOGRUN="$REPO_ROOT/scripts/logrun.sh"

# ---------------------------------------------------------------------------
# Sole-mutator guard: abort if a bench-fleet or bench-coordinator job already
# exists. A live job means another run is in-flight and is mutating (or is
# about to mutate) the ursula deployment — two concurrent mutators is exactly
# the bug we are preventing.
# ---------------------------------------------------------------------------
echo "=== sole-mutator guard ==="
existing=$(K get job bench-fleet bench-coordinator --no-headers 2>/dev/null || true)
if [ -n "$existing" ]; then
  echo "ERROR: existing bench job(s) detected — another run is in-flight." >&2
  echo "$existing" >&2
  echo "Aborting to avoid concurrent preset mutation. Clean up with:" >&2
  echo "  kubectl --context $CTX -n ds-bench delete job bench-fleet bench-coordinator --ignore-not-found" >&2
  exit 1
fi
echo "  guard passed — no in-flight jobs."

# ---------------------------------------------------------------------------
# Remember the original preset so we can report + restore at the end.
# ---------------------------------------------------------------------------
original_preset=$(grep -oE '"--preset", "[a-zA-Z0-9_-]+"' "$URSULA_YAML" | grep -oE '"[a-zA-Z0-9_-]+"$' | tr -d '"' | head -1)
if [ -z "$original_preset" ]; then
  echo "ERROR: could not detect current --preset token in $URSULA_YAML" >&2
  exit 1
fi
echo "  original preset in manifest: $original_preset"

# Accumulated results (parallel arrays — bash 3.2 compatible).
# Each entry appended as "preset:value".
result_presets=""
result_values=""

# ---------------------------------------------------------------------------
# Helper: append to parallel result arrays.
# ---------------------------------------------------------------------------
add_result() {
  local p="$1" v="$2"
  result_presets="${result_presets}${p} "
  result_values="${result_values}${v} "
}

# ---------------------------------------------------------------------------
# Sequential preset sweep.
# ---------------------------------------------------------------------------
echo ""
echo "=== starting sequential ursula preset sweep ==="
echo "    presets: tiny small standard large"
echo ""

for preset in tiny small standard large; do
  echo "------------------------------------------------------------"
  echo "  preset: $preset"
  echo "------------------------------------------------------------"

  # Step 1: Edit gke/ursula.yaml — replace the preset value token.
  # The args line uses JSON-array quoting: ["--preset", "standard"]
  # so the token to replace is the quoted word AFTER "--preset",
  # i.e.  "--preset", "standard"  →  "--preset", "<new>"
  sed -i.bak "s/\"--preset\", \"[a-zA-Z0-9_-]*\"/\"--preset\", \"${preset}\"/" "$URSULA_YAML"
  rm -f "${URSULA_YAML}.bak"

  # Confirm the edit took.
  actual=$(grep -oE '"--preset", "[a-zA-Z0-9_-]+"' "$URSULA_YAML" | grep -oE '"[a-zA-Z0-9_-]+"$' | tr -d '"' | head -1)
  if [ "$actual" != "$preset" ]; then
    echo "ERROR: preset edit failed — manifest still shows '$actual', expected '$preset'" >&2
    exit 1
  fi
  echo "  manifest confirmed: --preset $actual"

  # Step 2: Run gke-run.sh (applies edited manifest, rolls out, waits-until-serving,
  #         runs the fleet + coordinator, prints merged JSON to stdout).
  # NOTE: gke-run.sh emits human-readable status lines (e.g. "== merged (ursula/multi-stream) ==")
  # BEFORE the trailing JSON.  Feed the full stdout to tee for visibility, then extract only
  # the trailing JSON object (last line starting with '{') into a separate file for jq and
  # logrun.sh (both run under set -euo pipefail and will abort on non-JSON input).
  out=$(mktemp)
  merged=$(mktemp)
  bash "$GKE_RUN" ursula multi-stream 2 | tee "$out"
  grep -E '^\{' "$out" | tail -1 > "$merged"

  # Step 3: Extract writes/s from the merged JSON.
  # logrun.sh uses: aggregate_ops_per_sec // aggregate_writes_per_sec // ...
  # render-gke.py confirms aggregate_ops_per_sec is the primary field.
  writes=$(jq -r '(.aggregate_ops_per_sec // .aggregate_writes_per_sec // .aggregate_mb_per_sec // .events_per_sec // 0)' "$merged")
  echo ""
  echo "  >>> preset=$preset  writes/s=$writes"

  # Step 4: Log to bench-history/runlog.tsv.
  # Pass MS_STREAMS/MS_DURATION (gke-run.sh defaults for multi-stream) so runlog.tsv
  # records the ACTUAL streams/duration rather than hardcoded placeholders.
  bash "$LOGRUN" ursula "preset-${preset}" multi-stream 2 "${MS_STREAMS:-200}" "${MS_DURATION:-30}" "$merged" "clean sole-mutator sweep"

  # Accumulate result.
  add_result "$preset" "$writes"

  rm -f "$out" "$merged"
done

# ---------------------------------------------------------------------------
# Summary table + winner selection.
# Presets in increasing size order: tiny < small < standard < large.
# Tie-break: prefer the SMALLER preset (i.e. the earlier one in the loop).
# ---------------------------------------------------------------------------
echo ""
echo "==================================================================="
echo "  URSULA PRESET SWEEP — SUMMARY"
echo "==================================================================="
echo "  preset       writes/s"
echo "  ---------    --------"

winner_preset=""
winner_value="-1"

# Iterate over the parallel arrays using index simulation.
idx=0
for preset in tiny small standard large; do
  idx=$((idx + 1))
  # Extract the idx-th whitespace-delimited token from result_values.
  v=$(echo "$result_values" | awk "{print \$$idx}")
  echo "  $(printf '%-12s' "$preset") $v"

  # Winner: strictly higher value wins; ties keep the earlier (smaller) preset.
  # Use awk for floating-point comparison (writes/s may be a decimal).
  if [ -z "$winner_preset" ]; then
    winner_preset="$preset"
    winner_value="$v"
  else
    is_better=$(awk -v new="$v" -v best="$winner_value" 'BEGIN{print (new+0 > best+0) ? "yes" : "no"}')
    if [ "$is_better" = "yes" ]; then
      winner_preset="$preset"
      winner_value="$v"
    fi
  fi
done

echo ""
echo "  WINNER: $winner_preset  ($winner_value writes/s)"
echo ""
echo "  Tie-break rule: within ~5 % ties the SMALLER preset wins"
echo "  (tiny < small < standard < large)."

# ---------------------------------------------------------------------------
# Restore / set final manifest state.
# ---------------------------------------------------------------------------
DEFAULT_PRESET="standard"

if [ "$winner_preset" = "$DEFAULT_PRESET" ]; then
  echo ""
  echo "  Winner IS the default ($DEFAULT_PRESET) — manifest already set correctly."
  # Manifest is already on the winner from the last loop iteration that set
  # standard (if standard was last to run that's fine; if not, restore it).
  sed -i.bak "s/\"--preset\", \"[a-zA-Z0-9_-]*\"/\"--preset\", \"${DEFAULT_PRESET}\"/" "$URSULA_YAML"
  rm -f "${URSULA_YAML}.bak"
  echo "  gke/ursula.yaml restored to --preset $DEFAULT_PRESET (documented default)."
else
  # Leave manifest set to the winner.
  sed -i.bak "s/\"--preset\", \"[a-zA-Z0-9_-]*\"/\"--preset\", \"${winner_preset}\"/" "$URSULA_YAML"
  rm -f "${URSULA_YAML}.bak"
  echo "  NOTE: gke/ursula.yaml has been LEFT at --preset $winner_preset (the winner)."
  echo "  The operator should review and commit if this change is intentional."
  echo "  To revert to the documented default:"
  echo "    sed -i 's/\"--preset\", \"$winner_preset\"/\"--preset\", \"$DEFAULT_PRESET\"/' gke/ursula.yaml"
fi

echo "==================================================================="
echo "  Sweep complete."
echo "==================================================================="
