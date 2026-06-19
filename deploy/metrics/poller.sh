#!/usr/bin/env bash
set -euo pipefail
OUT="${METRICS_OUT:-/metrics/samples.csv}"
PROC_NAME="${SERVER_PROC:-durable-streams-server}"
INTERVAL="${METRICS_INTERVAL_S:-1}"
DATA_DIR="${DATA_DIR:-/data}"

# Block device backing the data dir (e.g. md0 = the striped local-SSD RAID0).
# Device-wide "sectors written" from /proc/diskstats counts ALL writeback to the
# disk, including the kernel flusher (kworker) that drains low-rate buffered
# writes — which the per-pid /proc/<pid>/io write_bytes counter misses (it only
# sees block I/O the server thread submits itself, e.g. a high-rate fdatasync).
# The server node is dedicated (nodeSelector), so the server is the only material
# writer to this device → device throughput == server disk throughput.
DEV="$(df "$DATA_DIR" 2>/dev/null | awk '$1 ~ /^\/dev\// {sub(/^\/dev\//,"",$1); print $1; exit}')"
[ -z "$DEV" ] && DEV="md0"   # fallback: GKE striped local-SSD RAID0

# field 10 of /proc/diskstats = sectors written; 512 bytes/sector.
disk_write_bytes() {
  local sec
  sec=$(awk -v d="$DEV" '$3==d{print $10; exit}' /proc/diskstats 2>/dev/null || echo 0)
  : "${sec:=0}"
  echo $(( sec * 512 ))
}

echo "ts_ms,rss_bytes,cpu_ticks,write_bytes" > "$OUT"
echo "poller: ${DATA_DIR} backed by device '${DEV}' (device-wide disk write_bytes)" >&2
while true; do
  # -f matches the full cmdline (not the 15-char-truncated comm that -x checks),
  # so a long binary name like "durable-streams-server" still matches; exclude self.
  pid="$(pgrep -f "$PROC_NAME" | grep -vx "$$" | head -1 || true)"
  if [ -n "$pid" ] && [ -r "/proc/$pid/stat" ]; then
    rss_pages=$(awk '{print $24}' "/proc/$pid/stat" 2>/dev/null || echo 0)   # field 24 = rss in pages
    rss=$(( rss_pages * $(getconf PAGE_SIZE) ))
    cpu=$(awk '{s=$0; sub(/^.*\) /,"",s); split(s,f," "); print f[12]+f[13]}' "/proc/$pid/stat" 2>/dev/null || echo 0)
    # Ground-truth disk write throughput, device-wide (see DEV note above).
    wbytes="$(disk_write_bytes)"
    : "${wbytes:=0}"
    ts=$(( $(date +%s%N) / 1000000 ))
    echo "${ts},${rss},${cpu},${wbytes}" >> "$OUT"
  fi
  sleep "$INTERVAL"
done
