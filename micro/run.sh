#!/usr/bin/env bash
# micro/run.sh — autonomous, reproducible benchmark orchestrator (container-friendly).
#
#   bash run.sh                 # full matrix (config.env)
#   PROFILE=smoke bash run.sh   # ~5 min smoke (validates the whole pipeline)
#   STUDIES=engines bash run.sh # a single study
#
# SR_DIR is optional; if set, ab_capture_env will record the git commit.
# BIN defaults to /usr/local/bin/durable-streams-server (set in config.env).
#
# Output: out/<timestamp>/{results.jsonl, meta.txt, RESULTS.md, run.log}
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/config.env"

# --- Reliability: keep the bench from starving the box ---
# Pin the orchestrator + children to BENCH_ALLOWED_CPUS via taskset, reserving
# the last core for the system. The per-cell SERVER is launched as a taskset
# background process (no systemd), killed cleanly on stop.
if [ -z "${DS_BENCH_SCOPED:-}" ]; then
  export DS_BENCH_SCOPED=1
  mkdir -p "$HERE/out"
  # single-run lock (auto-released if the holder dies); refuse to stack runs.
  exec 9>"$HERE/out/.run.lock"
  if ! flock -n 9; then
    echo "FATAL: a bench run is already active (out/.run.lock held). Run stop.sh first." >&2
    exit 1
  fi
  # watchdog: hard-stop the run after BENCH_MAX_SECONDS; exit early once it finishes.
  setsid bash -c '
    end=$((SECONDS + '"${BENCH_MAX_SECONDS}"'))
    while [ $SECONDS -lt $end ]; do
      pgrep -f "micro/run.sh" >/dev/null 2>&1 || exit 0
      sleep 30
    done
    echo "[watchdog] BENCH_MAX_SECONDS reached; stopping run"
    pkill -f "micro/run.sh"
    pkill -f "'"${BIN:-/usr/local/bin/durable-streams-server}"'"
  ' </dev/null >>"$HERE/out/watchdog.log" 2>&1 &
  # Re-exec pinned to BENCH_ALLOWED_CPUS (reserve the last core) + niced.
  if [ "${BENCH_SCOPE:-1}" = 1 ] && command -v taskset >/dev/null 2>&1; then
    exec taskset -c "${BENCH_ALLOWED_CPUS}" nice -n 10 ionice -c2 -n7 bash "$0" "$@"
  fi
fi

# Smoke profile: tiny matrix to validate the full pipeline fast.
if [ "${PROFILE:-}" = smoke ]; then
  DUR=3; REPEATS=1
  ENGINES="hyper raw uring"; ENGINE_SPECS="hyper:- raw:tail uring:-"
  READ_SIZES="1024 1048576"; CONNS_SWEEP="64 256"; SWEEP_SIZE=1024; SIZE_CONN=64
  SCALE_CPUSETS="0-1 0-7"; COLD_MEMS="infinity 512M"; COLD_STREAM_GIB=2
  SPLICE_SIZES="1048576"; TIER_SEG_BYTES=262144
  STUDIES="${STUDIES:-engines cpu_scaling memory_cold splice tiering}"
fi

# Fast profile: representative but ~3-4x shorter than the full matrix. Drops the
# redundant/low-signal cells (see README "Profiles"): DUR 12->8, REPEATS 3->2,
# read sizes 1K+1M only (no 16K), conns 64+256 only (no 16/1024), cpu sweep
# 2/4/8 cores (no 6), cold caps infinity+512M with a 2GB stream and no `always`
# offload mode, splice 1M only.
if [ "${PROFILE:-}" = fast ]; then
  DUR=8; REPEATS=2   # bare assign: config.env already set the defaults, so :- no-ops
  ENGINES="${ENGINES:-hyper raw uring}"; ENGINE_SPECS="${ENGINE_SPECS:-hyper:- raw:tail uring:-}"
  READ_SIZES="1024 16384 1048576"; CONNS_SWEEP="64 256"; SWEEP_SIZE=1024; SIZE_CONN=256
  SCALE_CPUSETS="0-1 0-3 0-7"
  COLD_MEMS="infinity 512M"; COLD_STREAM_GIB=2
  ENGINE_SPECS_COLD="${ENGINE_SPECS_COLD:-hyper:- raw:inline raw:tail uring:-}"
  SPLICE_SIZES="1048576"
  STUDIES="${STUDIES:-engines cpu_scaling memory_cold splice tiering}"
fi

STAMP="${STAMP:-$(date +%Y%m%d-%H%M%S)}"
export OUT="$HERE/out/$STAMP"
export RESULTS_JSONL="$OUT/results.jsonl"
mkdir -p "$OUT"
exec > >(tee -a "$OUT/run.log") 2>&1

export SR_DIR="${SR_DIR:-}" DUR REPEATS PORT="${PORT:-4700}" DATA="${DATA:-/data}" UNIT="${UNIT:-dsbench}"
export SERVER_CPUS CLIENT_CPUS SWEEP_SIZE SIZE_CONN READ_SIZES CONNS_SWEEP APPEND_MSG
export ENGINE_SPECS="${ENGINE_SPECS:-hyper:- raw:tail uring:-}"
export SCALE_CPUSETS COLD_MEMS COLD_STREAM_GIB SPLICE_SIZES TIER_SEG_BYTES TIER_S3
export SERVER_CPUS_DEFAULT="$SERVER_CPUS"
export SERVER_MEM=infinity
export BIN="${BIN:-/usr/local/bin/durable-streams-server}"
export BIN_TIER="${BIN_TIER:-/usr/local/bin/durable-streams-server-tier}"

source "$HERE/lib.sh"
for s in "$HERE"/studies/*.sh; do source "$s"; done

ab_log "=== micro start: studies=[$STUDIES] profile=${PROFILE:-full} out=$OUT ==="

# Pre-flight: stable clocks for low-variance numbers.
ab_log "setting cpu governor -> performance"
sudo cpupower frequency-set -g performance >/dev/null 2>&1 || \
  for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo tee "$c" >/dev/null 2>&1; done

# In container mode the binary is pre-installed; no build step.
[ -x "$BIN" ] || { ab_log "FATAL: binary not found ($BIN)"; exit 1; }
if printf '%s' "$STUDIES" | grep -qw tiering; then
  [ -x "$BIN_TIER" ] || ab_log "WARNING: tiering binary not found ($BIN_TIER); tiering study may fail"
fi

ab_capture_env
ab_reap   # clean slate

for study in $STUDIES; do
  fn="study_$study"
  if declare -F "$fn" >/dev/null; then
    ab_log ">>> running $study"
    "$fn"
  else
    ab_log "!!! unknown study: $study"
  fi
done

ab_log "=== aggregating ==="
python3 "$HERE/aggregate.py" "$RESULTS_JSONL" "$OUT/meta.txt" > "$OUT/RESULTS.md" && ab_log "wrote $OUT/RESULTS.md"
ab_log "=== micro DONE: $OUT ==="
