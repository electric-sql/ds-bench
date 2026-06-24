#!/usr/bin/env bash
# Saturation walker: ramp client pods up a per-stream-count ladder until the
# server's throughput plateaus, then pin + confirm. Reuses the lib-bench engine.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/scripts/lib-bench.sh"

# _sat_cell_dir <pods> <rep> — where a measured cell's merged.json/samples land.
_sat_cell_dir() {
  echo "${SAT_RESULT_ROOT:-${REPO_ROOT}/results/_sat}/${SAT_MODE}/n${SAT_SC}/p${1}-r${2}"
}

# measure_pods <pods> -> "cpu_pct thr". Default = a real write cell via the engine;
# overridable by the test via MEASURE_FN. Builds the 7-arg _run_cell_one call the
# matrix uses (gke-bench.sh run_one), deriving streams/pod = ceil(SAT_SC/pods) and
# the target/api/namespace from the addressing globals deploy_mode set (T_TARGET,
# T_API, T_NS). Throughput + cpu come straight back from _run_cell_one.
measure_pods() {
  local pods="$1"
  local sc="${SAT_SC:?measure_pods: SAT_SC unset (walk_cell sets it)}"
  local mode="${SAT_MODE:?measure_pods: SAT_MODE unset}"
  local rep="${SAT_REP:-1}"
  local perpod=$(( (sc + pods - 1) / pods ))
  local warmup="${WARMUP_SECS:-15}" settle="${SETTLE_SECS:-5}" dur="${MEASURE_SECS:-20}"
  local cell_dir; cell_dir="$(_sat_cell_dir "$pods" "$rep")"
  mkdir -p "$cell_dir"
  # setup-concurrency throttles stream CREATION (decoupled from pod count / load):
  # at high cardinality, pods × 256 concurrent creates overwhelmed the creation
  # endpoint (the 100k creation_choke). A lower per-pod value keeps total concurrent
  # creation bounded while pods still drive full load after setup.
  local setup_conc="${SETUP_CONCURRENCY:-32}" payload="${PAYLOAD_BYTES:-256}"
  local bench_cmd="multi-stream --target ${T_TARGET:?} --api-style ${T_API:?} ${T_NS:-} --streams ${perpod} --duration-secs ${dur} --payload-bytes ${payload} --setup-concurrency ${setup_conc} --warmup-secs ${warmup} --settle-secs ${settle}"
  local merge_cmd="ds-bench hdr-merge --hdr-dir /merge --results-dir /merge --label-prefix multi-stream-"
  _run_cell_one "${mode}-write-n${sc}-p${pods}" "$bench_cmd" "write" "$merge_cmd" "$pods" "$rep" "$cell_dir"
}

_sat_get() {  # _sat_get s <python-expr-over-Suite s> — read a suite field
  python3 - "$SUITE_FILE" "$2" <<'PY'
import sys; sys.path.insert(0, "scripts")
from suite import Suite
s = Suite.load(sys.argv[1])
print(eval(sys.argv[2]))
PY
}

walk_cell() {
  local mode="$1" sc="$2" cells_json="$3" digest="$4"
  local fn="${MEASURE_FN:-measure_pods}"
  export SAT_MODE="$mode" SAT_SC="$sc"
  local plateau; plateau="$(_sat_get s 's.saturation["plateau_pct"]')"
  local repeats; repeats="$(_sat_get s 's.saturation["repeats"]')"
  # Cap each rung at the stream count (+ dedup) so a low-cardinality cell never
  # over-provisions (pods > streams would drive more streams than intended).
  local ladder;  ladder="$(python3 -c "import sys;sys.path.insert(0,'scripts');from suite import Suite;from saturation import cap_ladder;s=Suite.load('$SUITE_FILE');print(' '.join(map(str,cap_ladder(s.ladder_for($sc),$sc))))")"

  local prev_pods=0 prev_thr=0 walk="[]" pods _cpu thr decision
  for pods in $ladder; do
    SAT_REP=1; reset_state "$mode"
    read -r _cpu thr < <("$fn" "$pods")
    walk="$(python3 -c "import json,sys; w=json.loads(sys.argv[1]); w.append([int(sys.argv[2]), float(sys.argv[3])]); print(json.dumps(w))" "$walk" "$pods" "$thr")"
    decision="$(python3 -c "import sys; sys.path.insert(0,'scripts'); from saturation import step_decision; print(step_decision(float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])))" "$prev_thr" "$thr" "$plateau")"
    case "$decision" in
      error)
        _record "$cells_json" "$sc" "$digest" "$walk" None 0 None False error creation_choke None
        return 0 ;;
      plateau)
        # saturated one rung back; confirm the pinned point with `repeats` reps.
        # Capture via $(...) — it BLOCKS until _confirm fully EXITS. (Previously
        # `read < <(_confirm)` returned on _confirm's first stdout line — reset_state's
        # "deployment rolled out" — leaving _confirm running in the BACKGROUND, so the
        # next stream-count's walk ran CONCURRENTLY with the lingering confirm: two
        # walkers, interleaved fleets, "already exists", stale merged reuse.)
        local conf_out conf_p50 conf_p99
        conf_out="$(_confirm "$fn" "$mode" "$prev_pods" "$repeats")"
        conf_p50="${conf_out%% *}"; conf_p99="${conf_out##* }"
        conf_p50="${conf_p50:-None}"; conf_p99="${conf_p99:-None}"   # never pass empty to _record
        _record "$cells_json" "$sc" "$digest" "$walk" "$prev_pods" "$prev_thr" "$conf_p50" True ok plateau "$conf_p99"
        return 0 ;;
      continue)
        prev_pods="$pods"; prev_thr="$thr" ;;
    esac
  done
  # ladder exhausted without plateau
  _record "$cells_json" "$sc" "$digest" "$walk" "$prev_pods" "$prev_thr" None False ok ladder_exhausted None
}

# _confirm <fn> <mode> <pods> <reps> — rerun the pinned pods `reps` times; echo the
# representative "p50 p99" (median latency, ms) read from each rep's merged.json.
# No merged.json (the unit test's mock fn) -> "None None".
_confirm() {
  local fn="$1" mode="$2" pods="$3" reps="$4" i p50s="" p99s="" cd p50 p99
  for ((i=1;i<=reps;i++)); do
    # reset_state -> stderr so _confirm's STDOUT carries ONLY the final "p50 p99"
    # result line (its rollout/reset chatter must not be captured as the result).
    SAT_REP="$i"; reset_state "$mode" >&2; "$fn" "$pods" >/dev/null
    cd="$(_sat_cell_dir "$pods" "$i")"
    p50="$(grep -oE '"p50_ms"[: ]*[0-9.]+' "$cd/merged.json" 2>/dev/null | grep -oE '[0-9.]+$' | head -1)"
    p99="$(grep -oE '"p99_ms"[: ]*[0-9.]+' "$cd/merged.json" 2>/dev/null | grep -oE '[0-9.]+$' | head -1)"
    p50s="$p50s ${p50:-}"; p99s="$p99s ${p99:-}"
  done
  local med='{a[NR]=$1} END{print (NR? a[int((NR+1)/2)] : "None")}'
  echo "$(echo "$p50s" | tr ' ' '\n' | grep -v '^$' | sort -n | awk "$med") $(echo "$p99s" | tr ' ' '\n' | grep -v '^$' | sort -n | awk "$med")"
}

_record() {  # bridge to cells.py — args: cells sc digest walk pods thr p50 sat status reason p99
  python3 -c "
import sys; sys.path.insert(0,'scripts')
import cells
# Tolerant parsing: a malformed pinned_pods/p50/p99/throughput must NEVER crash the
# record and drop an otherwise-good cell (a bad confirm value silently lost cells).
def _f(x, d=None):
    try: return float(x)
    except (ValueError, TypeError): return d
def _i(x, d=None):
    try: return int(x)
    except (ValueError, TypeError): return d
pp = None if sys.argv[5]=='None' else _i(sys.argv[5])
p50 = None if sys.argv[7]=='None' else _f(sys.argv[7])
p99 = None if sys.argv[11]=='None' else _f(sys.argv[11])
cells.record(sys.argv[1], int(sys.argv[2]), image_digest=sys.argv[3],
  walk=__import__('json').loads(sys.argv[4]), pinned_pods=pp, throughput=(_f(sys.argv[6]) or 0.0),
  p50=p50, p99=p99, saturated=(sys.argv[8]=='True'), status=sys.argv[9], reason=sys.argv[10])
" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}"
}
