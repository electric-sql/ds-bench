#!/usr/bin/env bash
# teardown-watchdog.sh — hard-deadline safety net. Independently force-deletes
# ALL bench-* GKE clusters at a deadline UNLESS run-all signalled clean completion
# (DONE_MARKER) first. Meant to be launched detached (nohup ... & disown) so it
# survives even if the orchestration / session dies — guaranteeing clusters never
# bill indefinitely because of a hang or bug that skips auto-teardown.
#
# Env:
#   DEADLINE_SECS   seconds from launch until the hard teardown fires (default 28800 = 8h)
#   DONE_MARKER     if this file appears, run-all already cleaned up -> exit quietly
#   POLL_SECS       how often to check (default 60)
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

DEADLINE_SECS="${DEADLINE_SECS:-28800}"
DONE_MARKER="${DONE_MARKER:-$(pwd)/.bench-state/run-all.done}"
POLL_SECS="${POLL_SECS:-60}"
START="$(date +%s)"
DEADLINE=$(( START + DEADLINE_SECS ))

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] watchdog: $*"; }
log "armed — deadline in ${DEADLINE_SECS}s; done-marker=$DONE_MARKER"

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  if [ -f "$DONE_MARKER" ]; then
    log "DONE marker present — orchestration finished cleanly; standing down (no teardown needed)."
    exit 0
  fi
  sleep "$POLL_SECS"
done

log "DEADLINE REACHED without completion — force-deleting all bench-* clusters."
deleted=0
gcloud container clusters list --format='value(name,zone)' 2>/dev/null | grep -E '^bench-' \
  | while read -r name zone; do
      log "force-deleting $name ($zone)"
      gcloud container clusters delete "$name" --zone "$zone" --quiet \
        && log "deleted $name" || log "WARN: failed to delete $name (will remain — CHECK MANUALLY)"
    done
log "watchdog teardown sweep complete."
