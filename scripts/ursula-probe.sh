#!/usr/bin/env bash
# Small FAST ursula preset probe. Sets --preset <value> in gke/ursula.yaml,
# redeploys, waits for ursula to actually serve, then runs a small multi-stream
# fleet (streams/duration overridable) and logs the result.
#
# Usage: ursula-probe.sh <preset> <streams> <dur_s> <pods> <out.json> [config-label]
set -euo pipefail
PRESET="${1:?preset}"; STREAMS="${2:?streams}"; DUR="${3:?dur}"; PODS="${4:?pods}"
OUT="${5:?out.json}"; LABEL="${6:-preset-${PRESET}-probe}"

export PROJECT="$(gcloud config get-value project 2>/dev/null)"
CTX="gke_${PROJECT}_europe-west1-b_ds-bench"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
K() { kubectl --context "$CTX" -n ds-bench "$@"; }

echo "=== probe: preset=$PRESET streams=$STREAMS dur=$DUR pods=$PODS ==="
# Set the --preset value in ursula.yaml (the args line).
perl -0pi -e 's/("--preset", ")[a-z0-9]+(")/${1}'"$PRESET"'${2}/' gke/ursula.yaml
grep -n -- '--preset' gke/ursula.yaml

# Apply + restart + wait for available, then poll serving from a client node.
envsubst '${PROJECT}' < gke/ursula.yaml | K apply -f - >/dev/null
K rollout restart deploy/ursula >/dev/null
K rollout status deploy/ursula --timeout=300s
# active HTTP readiness from a client node (3 consecutive answers)
K run "uprobe-$$" --rm --attach --restart=Never --image=curlimages/curl:latest \
  --overrides='{"spec":{"nodeSelector":{"role":"client"}}}' --command -- \
  /bin/sh -c "ok=0; for i in \$(seq 1 90); do code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://ursula:4437/ 2>/dev/null); case \"\$code\" in 2??|3??|4??|5??) ok=\$((ok+1));; *) ok=0;; esac; if [ \"\$ok\" -ge 3 ]; then echo serving; exit 0; fi; sleep 1; done; echo notserving; exit 1" </dev/null \
  && echo "  serving" || echo "  WARN probe non-zero, continuing"

# Run the small fleet; skip server re-deploy (we just did it).
GKE_RUN_SKIP_SERVER=1 MS_STREAMS="$STREAMS" MS_DURATION="$DUR" \
  scripts/gke-run.sh ursula multi-stream "$PODS" 2>&1 | tee "/tmp/uprobe-${PRESET}.log"

# The coordinator's merged JSON is the last JSON object in the log.
awk '/^== merged/{c=1} c' "/tmp/uprobe-${PRESET}.log" | sed -n '/^{/,/^}/p' > "$OUT"
echo "--- $OUT ---"; cat "$OUT"
WPS=$(jq -r '.aggregate_ops_per_sec // 0' "$OUT")
echo "PRESET=$PRESET WRITES_PER_SEC=$WPS"

# Log it.
scripts/logrun.sh ursula "$LABEL" multi-stream "$PODS" "$STREAMS" "$DUR" "$OUT" "preset sweep"
