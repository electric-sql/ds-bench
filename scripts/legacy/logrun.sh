#!/usr/bin/env bash
# Append a benchmark run to bench-history/runlog.tsv (over-time comparison).
# Usage: logrun.sh <system> <config> <workload> <pods> <streams> <dur_s> <merged.json> [notes]
set -euo pipefail
LOG="$(dirname "$0")/../bench-history/runlog.tsv"
sys=$1; cfg=$2; wl=$3; pods=$4; streams=$5; dur=$6; json=$7; notes="${8:-}"
ts=$(date -u +%Y-%m-%dT%H:%MZ)
vals=$(jq -r '[ (.aggregate_ops_per_sec // .aggregate_writes_per_sec // .aggregate_mb_per_sec // .events_per_sec // 0),
                (.p50_ms // 0), (.p99_ms // 0), (.p999_ms // 0), (.merged_count // 0) ] | @tsv' "$json")
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$sys" "$cfg" "$wl" "$pods" "$streams" "$dur" "$vals" >> "$LOG"
echo "logged: $sys/$cfg/$wl pods=$pods"
