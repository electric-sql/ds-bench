#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib-saturate.sh

# Inject canned throughputs keyed by pod count; reset_state is a no-op in the test.
reset_state() { :; }
declare -A CANNED=( [12]=400000 [16]=500000 [20]=560000 [24]=575000 )
measure_pods() { echo "0 ${CANNED[$1]:-0}"; }   # "cpu_pct thr"
export MEASURE_FN=measure_pods
export SUITE_FILE="suites/write-throughput.json"

tmp="$(mktemp -d)/cells.json"
walk_cell wal 1000 "$tmp" "digest123"

# 12->16 (+25%, continue), 16->20 (+12%, continue), 20->24 (+2.7% < 10% -> plateau, pin 20)
python3 - "$tmp" <<'PY'
import sys, json
cell = json.load(open(sys.argv[1]))["cells"]["1000"]
assert cell["saturated"] is True, cell
assert cell["reason"] == "plateau", cell
assert cell["pinned_pods"] == 20, cell
print("PASS walk_cell plateau")
PY

declare -A CANNED2=( [128]=300000 [200]=360000 [256]=420000 [320]=500000 [400]=600000 [512]=720000 )
measure_pods() { echo "0 ${CANNED2[$1]:-0}"; }
tmp2="$(mktemp -d)/cells.json"
walk_cell wal 100000 "$tmp2" "d2"
python3 - "$tmp2" <<'PY'
import sys, json
cell = json.load(open(sys.argv[1]))["cells"]["100000"]
assert cell["saturated"] is False and cell["reason"] == "ladder_exhausted", cell
print("PASS walk_cell ladder_exhausted")
PY
