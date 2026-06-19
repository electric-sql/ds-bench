#!/usr/bin/env bash
set -euo pipefail
OUT="${METRICS_OUT:-/metrics/samples.csv}"
PROC_NAME="${SERVER_PROC:-durable-streams-server}"
INTERVAL="${METRICS_INTERVAL_S:-1}"
echo "ts_ms,rss_bytes,cpu_ticks,write_bytes" > "$OUT"
while true; do
  # -f matches the full cmdline (not the 15-char-truncated comm that -x checks),
  # so a long binary name like "durable-streams-server" still matches; exclude self.
  pid="$(pgrep -f "$PROC_NAME" | grep -vx "$$" | head -1 || true)"
  if [ -n "$pid" ] && [ -r "/proc/$pid/stat" ]; then
    rss_pages=$(awk '{print $24}' "/proc/$pid/stat" 2>/dev/null || echo 0)   # field 24 = rss in pages
    rss=$(( rss_pages * $(getconf PAGE_SIZE) ))
    cpu=$(awk '{s=$0; sub(/^.*\) /,"",s); split(s,f," "); print f[12]+f[13]}' "/proc/$pid/stat" 2>/dev/null || echo 0)
    # Actual bytes the server caused to be sent to the block device (ground-truth
    # disk write throughput, independent of the ops×payload estimate). Needs same
    # uid (server+sidecar both root in-pod); 0 if /proc/<pid>/io is unreadable.
    wbytes=$(awk -F': ' '/^write_bytes:/{print $2}' "/proc/$pid/io" 2>/dev/null || echo 0)
    : "${wbytes:=0}"
    ts=$(( $(date +%s%N) / 1000000 ))
    echo "${ts},${rss},${cpu},${wbytes}" >> "$OUT"
  fi
  sleep "$INTERVAL"
done
