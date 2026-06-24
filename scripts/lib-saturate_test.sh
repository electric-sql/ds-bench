#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib-saturate.sh

# Self-contained suite fixture (decoupled from the shipped suites/*.json) with the
# exact ladders these cases exercise.
SUITE_DIR="$(mktemp -d)"
export SUITE_FILE="$SUITE_DIR/suite.json"
cat > "$SUITE_FILE" <<'JSON'
{
  "suite": "walk-test",
  "cluster": {},
  "saturation": { "plateau_pct": 10, "fleet_cpu": 0.5, "repeats": 1, "warmup_secs": 1, "measure_secs": 1 },
  "modes": ["wal"],
  "stream_counts": [1, 1000, 100000],
  "pod_ladder": {
    "1":      [1, 2],
    "1000":   [12, 16, 20, 24, 32],
    "100000": [128, 200, 256, 320, 400, 512]
  }
}
JSON

# Inject canned throughputs keyed by pod count; reset_state is a no-op in the test.
reset_state() { :; }
declare -A CANNED=( [12]=400000 [16]=500000 [20]=560000 [24]=575000 )
measure_pods() { echo "0 ${CANNED[$1]:-0}"; }   # "cpu_pct thr"
export MEASURE_FN=measure_pods

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

# Capping: n=1 ladder [1,2] caps to [1] — a single rung, no overshoot, no false plateau.
declare -A CANNED3=( [1]=900 [2]=1800 )
measure_pods() { echo "0 ${CANNED3[$1]:-0}"; }
tmp3="$(mktemp -d)/cells.json"
walk_cell wal 1 "$tmp3" "d3"
python3 - "$tmp3" <<'PY'
import sys, json
cell = json.load(open(sys.argv[1]))["cells"]["1"]
assert len(cell["walk"]) == 1, cell          # only pods=1 measured (2 was capped away)
assert cell["walk"][0][0] == 1, cell
assert cell["reason"] == "ladder_exhausted", cell
print("PASS walk_cell caps low cardinality")
PY

# _record must NEVER drop a cell on a malformed p50/throughput (regression: a bad
# confirm-p50 used to crash float() and silently lose the whole cell).
tmp4="$(mktemp -d)/cells.json"
_record "$tmp4" 1000 d4 '[[16,500000]]' 16 500000 "garbage-p50" True ok plateau 3.3
python3 - "$tmp4" <<'PY'
import sys, json
cell = json.load(open(sys.argv[1]))["cells"]["1000"]
assert cell["throughput"] == 500000.0 and cell["p50"] is None, cell   # bad p50 -> None
assert cell["p99"] == 3.3, cell                                       # valid p99 stored
assert cell["saturated"] is True and cell["reason"] == "plateau", cell
print("PASS _record tolerates malformed p50, keeps p99")
PY
