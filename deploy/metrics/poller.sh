#!/usr/bin/env bash
set -euo pipefail
OUT="${METRICS_OUT:-/metrics/samples.csv}"
PROC_NAME="${SERVER_PROC:-durable-streams-server}"
INTERVAL="${METRICS_INTERVAL_S:-1}"
echo "ts_ms,rss_bytes,cpu_ticks" > "$OUT"
while true; do
  pid="$(pgrep -x "$PROC_NAME" | head -1 || true)"
  if [ -n "$pid" ] && [ -r "/proc/$pid/stat" ]; then
    rss_pages=$(awk '{print $24}' "/proc/$pid/stat" 2>/dev/null || echo 0)   # field 24 = rss in pages
    rss=$(( rss_pages * $(getconf PAGE_SIZE) ))
    cpu=$(awk '{s=$0; sub(/^.*\) /,"",s); split(s,f," "); print f[12]+f[13]}' "/proc/$pid/stat" 2>/dev/null || echo 0)
    ts=$(( $(date +%s%N) / 1000000 ))
    echo "${ts},${rss},${cpu}" >> "$OUT"
  fi
  sleep "$INTERVAL"
done
