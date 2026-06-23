#!/usr/bin/env bash
# lib-bench_mem_test.sh — cluster-free unit test for compute_server_mem_mb.
# Exit 0 = PASS, non-zero = FAIL.
set -uo pipefail

export DS_TARGET=local
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export REPO_ROOT
# shellcheck source=scripts/lib-bench.sh
source "${REPO_ROOT}/scripts/lib-bench.sh"

tmp="$(mktemp -d /tmp/lib-bench-mem-XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
PASS=true

check() {  # name csv_content expected
  local name="$1" csv="$2" expected="$3" got
  printf '%s' "$csv" > "${tmp}/s.csv"
  got="$(compute_server_mem_mb "${tmp}/s.csv")"
  if [ "$got" != "$expected" ]; then
    echo "FAIL [$name]: expected '$expected', got '$got'"; PASS=false
  else
    echo "ok [$name]: $got"
  fi
}

# 1 MiB = 1048576 bytes. start=100MiB, peak=300MiB, end=250MiB -> peak=300 drift=150
check growth \
  $'ts_ms,rss_bytes,cpu_ticks,write_bytes\n1000,104857600,0,0\n2000,314572800,0,0\n3000,262144000,0,0\n' \
  "300 150"

# settles back below start: start=300MiB end=200MiB peak=300MiB -> peak=300 drift=-100
check negative_drift \
  $'ts_ms,rss_bytes,cpu_ticks,write_bytes\n1000,314572800,0,0\n2000,209715200,0,0\n' \
  "300 -100"

# header only, no data rows -> "0 0"
check empty \
  $'ts_ms,rss_bytes,cpu_ticks,write_bytes\n' \
  "0 0"

$PASS && { echo "PASS"; exit 0; } || { echo "FAILED"; exit 1; }
