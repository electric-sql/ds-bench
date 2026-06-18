# micro/lib.sh — shared primitives for the autonomous benchmark suite.
#
# Isolation model:
#   * the SERVER is launched with taskset-pinned background process; no systemd
#     required (container-friendly). SERVER_CPUS pins it to a core set.
#   * the CLIENT (wrk) is taskset-pinned to a DISJOINT core set, so client and
#     server never steal each other's cores — this is what exposes true engine
#     differences (same-box contention otherwise compresses them).
#   * CPU accounting uses /proc/<pid>/stat rather than cgroup CPUUsageNSec.
#
# Results are emitted as one JSON object per cell to $RESULTS_JSONL; aggregate.py
# turns them into RESULTS.md with median +/- stddev across repeats.

set -u

# ---- config (overridable via env / config.env) ----
SR_DIR="${SR_DIR:-}"               # optional; only used for ab_capture_env git commit
BIN="${BIN:-/usr/local/bin/durable-streams-server}"
PORT="${PORT:-4700}"
DATA="${DATA:-/data}"
UNIT="${UNIT:-dsbench}"            # kept for reap/stop compatibility
SERVER_CPUS="${SERVER_CPUS:-0-5}" # cpuset for the server (8-core node: 0-5)
CLIENT_CPUS="${CLIENT_CPUS:-6-7}" # cpuset for wrk (8-core node: 6-7)
SERVER_MEM="${SERVER_MEM:-infinity}" # MemoryMax (cgroup; only used when delegated cgroup available)
DUR="${DUR:-10}"
REPEATS="${REPEATS:-3}"
RUN_USER="${RUN_USER:-$(id -un)}"
RUN_GROUP="${RUN_GROUP:-$(id -gn)}"
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUT:-$_LIB_DIR/out/run}"
RESULTS_JSONL="${RESULTS_JSONL:-$OUT/results.jsonl}"

URL="http://127.0.0.1:${PORT}/s"
SRV_MAIN_PID=""

mkdir -p "$OUT"

ab_log() { echo "[$(date +%H:%M:%S)] $*"; }

# Emit one result row as a JSON line. Args are key=value pairs; values are
# emitted as numbers when numeric, strings otherwise.
ab_emit() {
  local json="{" first=1 kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    [ $first -eq 1 ] || json+=","
    first=0
    if [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then json+="\"$k\":$v"; else json+="\"$k\":\"$v\""; fi
  done
  json+="}"
  echo "$json" >> "$RESULTS_JSONL"
}

# ---- safety: reap anything we might have left behind ----
ab_reap() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
  pkill -f "curl -s http://127.0.0.1:${PORT}" 2>/dev/null
  pkill -f "$BIN" 2>/dev/null
  true
}
trap 'ab_reap' EXIT INT TERM

# ---- environment capture (reproducibility header) ----
ab_capture_env() {
  local f="$OUT/meta.txt"
  {
    echo "date: $(date -u +%FT%TZ)"
    echo "host: $(hostname)"
    echo "kernel: $(uname -srm)"
    echo "cpu: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')"
    echo "cores: $(nproc)"
    echo "governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
    echo "turbo_no_turbo: $(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo n/a)"
    echo "ram: $(free -h | awk '/Mem:/{print $2}')"
    echo "commit: $([ -n "${SR_DIR:-}" ] && cd "$SR_DIR" && git rev-parse --short HEAD 2>/dev/null || echo n/a)"
    echo "rustc: $(rustc --version 2>/dev/null || echo n/a)"
    echo "server_cpus_default: $SERVER_CPUS"
    echo "client_cpus_default: $CLIENT_CPUS"
    echo "dur: ${DUR}s  repeats: $REPEATS"
  } | tee "$f"
}

# ---- server lifecycle (taskset background process, no systemd) ----
# start_server <engine> <mode> [extra server args...]
#   SERVER_CPUS is read from the environment per-cell.
#   SERVER_MEM: if a delegated cgroup at /sys/fs/cgroup/dsbench is available,
#   apply a MemoryMax-equivalent constraint; otherwise skip (with a notice).
SERVER_PID=""

start_server() {
  local eng="$1" mode="$2"; shift 2
  ab_reap
  rm -rf "$DATA"; mkdir -p "$DATA"
  local args=(--host 127.0.0.1 --port "$PORT" --data-dir "$DATA" --long-poll-timeout-ms 30000)
  # NO_HTTP_ENGINE_FLAG=1 for a single-engine build that dropped --http-engine.
  [ "${NO_HTTP_ENGINE_FLAG:-0}" = 1 ] || args+=(--http-engine "$eng")
  { [ "$eng" = raw ] || [ "${NO_HTTP_ENGINE_FLAG:-0}" = 1 ]; } && args+=(--read-offload "$mode")
  args+=("$@")
  # Launch under taskset (no systemd); capture PID for clean stop.
  taskset -c "${SERVER_CPUS:-0-7}" "$BIN" "${args[@]}" &
  SERVER_PID=$!
  # readiness: poll until the socket answers (any HTTP response = up).
  local i
  for i in $(seq 1 100); do
    if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${PORT}/__nope" 2>/dev/null; then break; fi
    sleep 0.1
  done
  # Verify server is still running
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    ab_log "server FAILED to start ($eng/$mode)"; SERVER_PID=""; return 1
  fi
  SRV_MAIN_PID="$SERVER_PID"
}

stop_server() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
  sleep 0.5
}

# cumulative server CPU nanoseconds — read from /proc/<pid>/stat (all threads).
# Returns empty string if the server isn't running (caller handles that gracefully).
server_cpu_nsec() {
  local pid="${SRV_MAIN_PID:-}"
  [ -z "$pid" ] && return
  # /proc/<pid>/stat fields 14+15 (utime+stime) are after the comm field (field 2).
  # The comm can contain spaces (e.g. "(durable streams)"), so positional $14+$15
  # would be wrong.  Strip everything up to and including the closing ')' first,
  # then the 12th+13th remaining fields are utime+stime.
  local ticks hz
  ticks=$(awk '{s=$0; sub(/^.*\) /,"",s); split(s,f," "); print f[12]+f[13]}' "/proc/$pid/stat" 2>/dev/null) || return
  hz=$(getconf CLK_TCK 2>/dev/null); hz="${hz:-100}"
  # convert ticks -> nanoseconds
  awk -v t="$ticks" -v h="$hz" 'BEGIN{printf "%.0f", t/h*1e9}'
}

# seed stream "s" with exactly $1 bytes (binary); assert a bare GET returns them.
seed() {
  curl -s -X PUT "$URL" -H 'Content-Type: application/octet-stream' >/dev/null
  head -c "$1" /dev/zero | tr '\0' x > /tmp/body.bin
  curl -s -X POST "$URL" -H 'Content-Type: application/octet-stream' --data-binary @/tmp/body.bin >/dev/null
  local got; got=$(curl -s "$URL" | wc -c)
  [ "$got" = "$1" ] || { ab_log "SEED FAIL wanted=$1 got=$got"; return 1; }
}

# measure <conn> <url> [wrk-args...] -> prints "rps p50ms p99ms maxms cpu%"
# CPU% is the server cgroup's CPU over the wrk window (taskset-pinned client).
measure() {
  local conn="$1" url="$2"; shift 2
  local c0 c1 out
  c0=$(server_cpu_nsec); c0=${c0:-0}
  out=$(taskset -c "$CLIENT_CPUS" wrk -t4 -c"$conn" -d"${DUR}s" --latency "$@" "$url" 2>&1)
  c1=$(server_cpu_nsec); c1=${c1:-0}
  local rps p50 p99 mx cpu
  rps=$(echo "$out" | awk '/Requests\/sec/{print $2}')
  p50=$(echo "$out" | awk '$1=="50%"{print $2}')
  p99=$(echo "$out" | awk '$1=="99%"{print $2}')
  mx=$(echo "$out"  | awk '$1=="Latency"{print $4; exit}')
  cpu=$(awk -v a="$c0" -v b="$c1" -v d="$DUR" 'BEGIN{printf "%.0f",(b-a)/1e9/d*100}')
  # normalize latency to ms
  echo "$(num "$rps") $(lat_ms "$p50") $(lat_ms "$p99") $(lat_ms "$mx") ${cpu:-0}"
}

# strip thousands and non-numerics; "NA" -> 0
num() { local v="${1:-}"; v="${v//,/}"; [[ "$v" =~ ^-?[0-9.]+$ ]] && echo "$v" || echo 0; }
# wrk latency tokens like 162.00us / 1.23ms / 2.01s -> milliseconds
lat_ms() {
  local v="${1:-}"
  case "$v" in
    *us) echo "$(awk -v x="${v%us}" 'BEGIN{printf "%.3f",x/1000}')" ;;
    *ms) echo "${v%ms}" ;;
    *s)  echo "$(awk -v x="${v%s}" 'BEGIN{printf "%.3f",x*1000}')" ;;
    *)   echo 0 ;;
  esac
}
