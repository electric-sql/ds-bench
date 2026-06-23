# Write-Throughput Benchmark Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the fixed-pods-per-cell write-throughput benchmark with a declarative, resumable suite that ramps client pods per stream-count until the server saturates, then aggregates results into a report.

**Architecture:** A thin bash driver (`scripts/bench`) reads a suite JSON and orchestrates, per mode, a saturation **walker** (`scripts/lib-saturate.sh`) that reuses the existing engine in `scripts/lib-bench.sh` (deploy/fleet/merge). Pure logic lives in small Python modules (`suite.py`, `cells.py`, `saturation.py`, `report.py`) that are unit-tested; bash handles cluster/k8s orchestration. State + results live in one per-mode `cells.json`.

**Tech Stack:** Bash (orchestration, reusing `lib-bench.sh`), Python 3 (config/state/report logic, stdlib only — `json`, `csv`, `argparse`), `kubectl`/`gcloud`/`mc` (k8s + MinIO), `pytest` (Python tests), `*_test.sh` scripts (bash tests, matching the repo's existing `scripts/lib-bench_mem_test.sh` pattern).

## Global Constraints

- **`fleet_cpu` is 0.5, never 2** — 2 over-subscribes the client pool and causes scheduling races / under-driving.
- **`plateau_pct` default 10** — saturation = throughput growth below this fraction on the next ladder rung. This is the **primary** signal.
- **`cpu_pct` is durable(wal)-only** — ursula and s2 report 0, so their saturation relies solely on the plateau signal. CPU is a confirmatory secondary signal for wal only.
- **`pod_ladder` is a per-stream-count map** (`{"1000":[12,16,20,24,32], ...}`). The first rung is the seed; the last is the climb ceiling. There is **no** separate `seed_pods`.
- **`repeats` apply only at the pinned (saturating) pod count** — the ramp uses 1 rep per rung.
- **State clear is pod-restart based:** `kubectl rollout restart` + an initContainer running `rm -rf /data/*` (wal + ursula). **s2 additionally empties its MinIO bucket** (`mc rm --recursive`) because its state lives in the object store, not the pod.
- **One cluster per mode** (`bench-wal`, `bench-ursula`, `bench-s2`), each in its own zone, each with an isolated `KUBECONFIG`. Clusters **persist**; teardown is a separate explicit step.
- **`wal` is the only durable config** benchmarked (no strict / strict-iouring / cache).
- **State + results live in one per-mode `cells.json`** (no `pins.json`/`pins.py`). Each cell is stamped with the **server image digest**; a changed digest re-runs that cell.
- **A failed/choked cell is recorded `status:"error"`, never pinned as a real throughput** (the 100k creation-choke must not masquerade as a ceiling).
- **The report is aggregated data + a markdown skeleton** (`aggregate.csv`/`aggregate.json` + `report.md` with empty Findings/Caveats headers) — deterministically regenerable with no cluster.
- Python: stdlib only, `python3`, no third-party deps except `pytest` for tests.

---

### Task 1: Suite config loader + example suite

**Files:**
- Create: `suites/write-throughput.json`
- Create: `scripts/suite.py`
- Test: `scripts/suite_test.py`

**Interfaces:**
- Produces: `Suite.load(path) -> Suite`; properties `Suite.name:str`, `Suite.modes:list[str]`, `Suite.stream_counts:list[int]`, `Suite.cluster:dict`, `Suite.saturation:dict`; method `Suite.ladder_for(stream_count:int) -> list[int]`.

- [ ] **Step 1: Write the example suite file**

`suites/write-throughput.json`:
```json
{
  "suite": "write-throughput",
  "cluster": {
    "server_machine": "c4d-standard-16-lssd",
    "client_machine": "n2d-standard-32",
    "client_nodes": 6,
    "region": "europe-west4"
  },
  "saturation": {
    "plateau_pct": 10,
    "fleet_cpu": 0.5,
    "repeats": 3,
    "warmup_secs": 15,
    "measure_secs": 20
  },
  "modes": ["wal", "ursula", "s2"],
  "stream_counts": [1, 10, 100, 1000, 10000, 100000],
  "pod_ladder": {
    "1":      [2, 4, 8],
    "10":     [2, 4, 8],
    "100":    [4, 8, 16],
    "1000":   [12, 16, 20, 24, 32],
    "10000":  [32, 64, 96, 128, 160, 200],
    "100000": [128, 200, 256, 320, 400, 512]
  }
}
```

- [ ] **Step 2: Write the failing test**

`scripts/suite_test.py`:
```python
import os, pytest
from suite import Suite

SUITE = os.path.join(os.path.dirname(__file__), "..", "suites", "write-throughput.json")

def test_loads_fields():
    s = Suite.load(SUITE)
    assert s.name == "write-throughput"
    assert s.modes == ["wal", "ursula", "s2"]
    assert s.stream_counts == [1, 10, 100, 1000, 10000, 100000]
    assert s.cluster["server_machine"] == "c4d-standard-16-lssd"
    assert s.saturation["plateau_pct"] == 10
    assert s.saturation["fleet_cpu"] == 0.5

def test_ladder_for():
    s = Suite.load(SUITE)
    assert s.ladder_for(1000) == [12, 16, 20, 24, 32]
    assert s.ladder_for(100000) == [128, 200, 256, 320, 400, 512]

def test_ladder_for_missing_raises():
    s = Suite.load(SUITE)
    with pytest.raises(KeyError):
        s.ladder_for(999)
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd scripts && python3 -m pytest suite_test.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'suite'`

- [ ] **Step 4: Write the implementation**

`scripts/suite.py`:
```python
"""Load and expose a benchmark suite JSON (see suites/write-throughput.json)."""
import json

class Suite:
    def __init__(self, data):
        self._d = data

    @classmethod
    def load(cls, path):
        with open(path) as f:
            return cls(json.load(f))

    @property
    def name(self):            return self._d["suite"]
    @property
    def modes(self):           return list(self._d["modes"])
    @property
    def stream_counts(self):   return list(self._d["stream_counts"])
    @property
    def cluster(self):         return dict(self._d["cluster"])
    @property
    def saturation(self):      return dict(self._d["saturation"])

    def ladder_for(self, stream_count):
        ladder = self._d["pod_ladder"]
        key = str(stream_count)
        if key not in ladder:
            raise KeyError(f"no pod_ladder entry for stream_count {stream_count}")
        return list(ladder[key])
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd scripts && python3 -m pytest suite_test.py -v`
Expected: PASS (3 passed)

- [ ] **Step 6: Commit**

```bash
git add suites/write-throughput.json scripts/suite.py scripts/suite_test.py
git commit -m "bench: declarative suite JSON + loader (suite.py)"
```

---

### Task 2: Saturation step decision

**Files:**
- Modify: `scripts/saturation.py` (add `step_decision`; keep existing `classify`/`extract_throughput`)
- Test: `scripts/saturation_step_test.py`

**Interfaces:**
- Produces: `step_decision(prev_thr:float, thr:float, plateau_pct:float) -> str` returning `"continue"` or `"plateau"`. `prev_thr <= 0` (first rung) always returns `"continue"`. `thr <= 0` (collapse/error) returns `"error"`.

- [ ] **Step 1: Write the failing test**

`scripts/saturation_step_test.py`:
```python
from saturation import step_decision

def test_first_rung_continues():
    assert step_decision(0, 100000, 10) == "continue"

def test_big_gain_continues():
    # +27% gain → keep climbing
    assert step_decision(300000, 380000, 10) == "continue"

def test_small_gain_plateaus():
    # +2.4% gain < 10% → saturated
    assert step_decision(410000, 420000, 10) == "plateau"

def test_exact_threshold_plateaus():
    # exactly 10% is not "above" the threshold → plateau
    assert step_decision(100000, 110000, 10) == "plateau"

def test_collapse_is_error():
    assert step_decision(400000, 0, 10) == "error"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd scripts && python3 -m pytest saturation_step_test.py -v`
Expected: FAIL — `ImportError: cannot import name 'step_decision'`

- [ ] **Step 3: Add the implementation to `scripts/saturation.py`**

Append to `scripts/saturation.py`:
```python
def step_decision(prev_thr, thr, plateau_pct):
    """Decide the walker's next move from consecutive ladder-rung throughputs.

    "error"    -> throughput collapsed to ~0 (choke/thrash); do not pin.
    "continue" -> first rung, or gain still above plateau threshold.
    "plateau"  -> gain at or below plateau threshold; server saturated.
    """
    if thr <= 0:
        return "error"
    if prev_thr <= 0:
        return "continue"
    gain = (thr - prev_thr) / prev_thr
    return "continue" if gain > plateau_pct / 100.0 else "plateau"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd scripts && python3 -m pytest saturation_step_test.py -v`
Expected: PASS (5 passed)

- [ ] **Step 5: Commit**

```bash
git add scripts/saturation.py scripts/saturation_step_test.py
git commit -m "bench: add step_decision (plateau-primary saturation signal)"
```

---

### Task 3: Per-mode cells store (results + state)

**Files:**
- Create: `scripts/cells.py`
- Test: `scripts/cells_test.py`

**Interfaces:**
- Produces:
  - `record(path, stream_count, *, image_digest, walk, pinned_pods, throughput, p99, saturated, status, reason)` — upsert one cell into the per-mode `cells.json` at `path`.
  - `status_of(path, stream_count, image_digest) -> str` — returns `"saturated"`, `"resume"`, `"error"`, or `"absent"`. A cell whose stored digest differs from `image_digest` is treated as `"absent"` (invalidated).
  - `all_cells(path) -> list[dict]` — every cell entry (for the report).

- [ ] **Step 1: Write the failing test**

`scripts/cells_test.py`:
```python
import os, tempfile, cells

def _tmp():
    return os.path.join(tempfile.mkdtemp(), "cells.json")

def test_record_then_saturated():
    p = _tmp()
    cells.record(p, 1000, image_digest="abc", walk=[[16,500000],[20,510000]],
                 pinned_pods=16, throughput=500000, p99=2.1,
                 saturated=True, status="ok", reason="plateau")
    assert cells.status_of(p, 1000, "abc") == "saturated"

def test_absent_when_unseen():
    p = _tmp()
    cells.record(p, 1000, image_digest="abc", walk=[], pinned_pods=16,
                 throughput=1, p99=1, saturated=True, status="ok", reason="plateau")
    assert cells.status_of(p, 10000, "abc") == "absent"

def test_digest_change_invalidates():
    p = _tmp()
    cells.record(p, 1000, image_digest="abc", walk=[], pinned_pods=16,
                 throughput=1, p99=1, saturated=True, status="ok", reason="plateau")
    assert cells.status_of(p, 1000, "xyz") == "absent"

def test_ladder_exhausted_resumes():
    p = _tmp()
    cells.record(p, 100000, image_digest="abc", walk=[[400,300000]], pinned_pods=400,
                 throughput=300000, p99=9, saturated=False, status="ok",
                 reason="ladder_exhausted")
    assert cells.status_of(p, 100000, "abc") == "resume"

def test_error_status():
    p = _tmp()
    cells.record(p, 100000, image_digest="abc", walk=[[200,0]], pinned_pods=None,
                 throughput=0, p99=None, saturated=False, status="error",
                 reason="creation_choke")
    assert cells.status_of(p, 100000, "abc") == "error"

def test_upsert_overwrites():
    p = _tmp()
    cells.record(p, 1000, image_digest="abc", walk=[], pinned_pods=16, throughput=1,
                 p99=1, saturated=False, status="ok", reason="ladder_exhausted")
    cells.record(p, 1000, image_digest="abc", walk=[], pinned_pods=24, throughput=2,
                 p99=1, saturated=True, status="ok", reason="plateau")
    assert cells.status_of(p, 1000, "abc") == "saturated"
    assert len(cells.all_cells(p)) == 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd scripts && python3 -m pytest cells_test.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'cells'`

- [ ] **Step 3: Write the implementation**

`scripts/cells.py`:
```python
"""Per-mode results-and-state store. One JSON file per mode; one entry per
stream_count. Replaces pins.json — this file is both the resume state and the
report source."""
import json, os

def _load(path):
    if not os.path.exists(path):
        return {"cells": {}}
    with open(path) as f:
        return json.load(f)

def _save(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)

def record(path, stream_count, *, image_digest, walk, pinned_pods, throughput,
           p99, saturated, status, reason):
    data = _load(path)
    data["cells"][str(stream_count)] = {
        "stream_count": stream_count,
        "image_digest": image_digest,
        "walk": walk,                # [[pods, throughput], ...]
        "pinned_pods": pinned_pods,
        "throughput": throughput,
        "p99": p99,
        "saturated": saturated,
        "status": status,            # "ok" | "error"
        "reason": reason,            # "plateau" | "cpu" | "ladder_exhausted" | "creation_choke" | ...
    }
    _save(path, data)

def status_of(path, stream_count, image_digest):
    cell = _load(path)["cells"].get(str(stream_count))
    if cell is None or cell.get("image_digest") != image_digest:
        return "absent"
    if cell.get("status") == "error":
        return "error"
    if cell.get("saturated"):
        return "saturated"
    return "resume"

def all_cells(path):
    return list(_load(path)["cells"].values())
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd scripts && python3 -m pytest cells_test.py -v`
Expected: PASS (6 passed)

- [ ] **Step 5: Commit**

```bash
git add scripts/cells.py scripts/cells_test.py
git commit -m "bench: per-mode cells.json store (results + resume state, replaces pins)"
```

---

### Task 4: State reset (initContainer + `reset_state`)

**Files:**
- Modify: `gke/durable-streams.yaml` (add data-dir-wipe initContainer)
- Modify: ursula manifest (find via `grep -l 'app: ursula' gke/*.yaml`; add the same initContainer)
- Modify: `scripts/lib-bench.sh` (add `reset_state` function)
- Test: `scripts/reset_state_test.sh`

**Interfaces:**
- Produces: `reset_state <mode>` (bash function in `lib-bench.sh`). For `wal`/`ursula`: `kubectl rollout restart` the server Deployment, then wait for readiness. For `s2`: empty the s2 MinIO bucket via the `mc` client pod, then restart. Honors `$KCTX` and `$RESET_DRYRUN` (when set to `1`, echoes the commands instead of running them — for testing).

- [ ] **Step 1: Add the initContainer to `gke/durable-streams.yaml`**

In the Deployment pod `spec:`, alongside the existing `containers:`, add (before `containers:`):
```yaml
      initContainers:
        - name: wipe-data
          image: ${IMG_SERVER}
          imagePullPolicy: ${PULL_POLICY}
          command: ["sh", "-c", "rm -rf /data/* /data/.[!.]* 2>/dev/null; true"]
          volumeMounts:
            - { name: data, mountPath: /data }
```
(Use the same `data` volume name the main container mounts at `/data`.)

- [ ] **Step 2: Add the identical initContainer to the ursula manifest**

Same block, in the ursula Deployment, mounting ursula's data volume at its data path (check the existing `volumeMounts` for the path; ursula's is also an `emptyDir`).

- [ ] **Step 3: Write the failing test**

`scripts/reset_state_test.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib-bench.sh
export RESET_DRYRUN=1 KCTX=test-ctx

out="$(reset_state wal)"
echo "$out" | grep -q "rollout restart" || { echo "FAIL wal: no rollout restart"; exit 1; }

out="$(reset_state s2)"
echo "$out" | grep -q "mc rm" || { echo "FAIL s2: no bucket wipe"; exit 1; }
echo "$out" | grep -q "rollout restart" || { echo "FAIL s2: no rollout restart"; exit 1; }

echo "PASS reset_state"
```

- [ ] **Step 4: Run test to verify it fails**

Run: `bash scripts/reset_state_test.sh`
Expected: FAIL — `reset_state: command not found` (function not defined yet)

- [ ] **Step 5: Add `reset_state` to `scripts/lib-bench.sh`**

Append to `scripts/lib-bench.sh` (after the existing helpers):
```bash
# reset_state <mode> — clear server state between cells WITHOUT recreating the
# cluster. Pod restart wipes the emptyDir (+ the wipe-data initContainer guarantees
# /data is empty even on NVMe). s2 keeps state in MinIO, so its bucket is emptied too.
# RESET_DRYRUN=1 echoes commands instead of running them (for tests).
reset_state() {
  local mode="$1" run
  if [ "${RESET_DRYRUN:-0}" = "1" ]; then run="echo"; else run=""; fi
  case "$mode" in
    s2)
      $run kubectl --context "$KCTX" -n ds-bench exec deploy/minio -- \
        mc rm --recursive --force local/s2-streams/ 2>/dev/null || true
      $run kubectl --context "$KCTX" -n ds-bench rollout restart deploy/s2
      [ -z "$run" ] && kubectl --context "$KCTX" -n ds-bench rollout status deploy/s2 --timeout=120s
      ;;
    wal)
      $run kubectl --context "$KCTX" -n ds-bench rollout restart deploy/durable-streams
      [ -z "$run" ] && kubectl --context "$KCTX" -n ds-bench rollout status deploy/durable-streams --timeout=120s
      ;;
    ursula)
      $run kubectl --context "$KCTX" -n ds-bench rollout restart deploy/ursula
      [ -z "$run" ] && kubectl --context "$KCTX" -n ds-bench rollout status deploy/ursula --timeout=120s
      ;;
    *) echo "reset_state: unknown mode '$mode'" >&2; return 2 ;;
  esac
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bash scripts/reset_state_test.sh`
Expected: `PASS reset_state`

- [ ] **Step 7: Commit**

```bash
git add gke/durable-streams.yaml gke/*ursula* scripts/lib-bench.sh scripts/reset_state_test.sh
git commit -m "bench: per-mode reset_state (pod-restart + data-dir wipe; s2 bucket clear)"
```

---

### Task 5: Saturation walker

**Files:**
- Create: `scripts/lib-saturate.sh`
- Test: `scripts/lib-saturate_test.sh`

**Interfaces:**
- Consumes: `reset_state` (Task 4), `_run_cell_one` (existing in `lib-bench.sh`, returns `"cpu_pct thr"`), `saturation.py step_decision` (Task 2), `cells.py record` (Task 3), `Suite.ladder_for` (Task 1).
- Produces: `walk_cell <mode> <stream_count> <cells_json> <image_digest>` — walks that stream-count's ladder, records the result in `cells_json`. Reads the ladder + saturation params from `$SUITE_FILE`. For testability it invokes throughput measurement through `measure_pods <pods>`, which defaults to calling `_run_cell_one` but can be overridden by setting `MEASURE_FN` to a function name (the test injects canned throughputs).

- [ ] **Step 1: Write the failing test**

`scripts/lib-saturate_test.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
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

# 12→16 (+25%, continue), 16→20 (+12%, continue), 20→24 (+2.7% < 10% → plateau, pin 20)
python3 - "$tmp" <<'PY'
import sys, json
cell = json.load(open(sys.argv[1]))["cells"]["1000"]
assert cell["saturated"] is True, cell
assert cell["reason"] == "plateau", cell
assert cell["pinned_pods"] == 20, cell
print("PASS walk_cell plateau")
PY
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/lib-saturate_test.sh`
Expected: FAIL — `scripts/lib-saturate.sh: No such file or directory`

- [ ] **Step 3: Write the implementation**

`scripts/lib-saturate.sh`:
```bash
#!/usr/bin/env bash
# Saturation walker: ramp client pods up a per-stream-count ladder until the
# server's throughput plateaus, then pin + confirm. Reuses the lib-bench engine.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/scripts/lib-bench.sh"

# measure_pods <pods> -> "cpu_pct thr". Default = the real engine cell; overridable.
measure_pods() { _run_cell_one "$1"; }

_sat_get() {  # _sat_get <python-expr-over-Suite s> — read a suite field
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
  local plateau; plateau="$(_sat_get s 's.saturation["plateau_pct"]')"
  local repeats; repeats="$(_sat_get s 's.saturation["repeats"]')"
  local ladder;  ladder="$(_sat_get s "' '.join(map(str, s.ladder_for($sc)))")"

  local prev_pods=0 prev_thr=0 walk="[]"
  for pods in $ladder; do
    reset_state "$mode"
    read -r _cpu thr < <("$fn" "$pods")
    walk="$(python3 -c "import json,sys; w=json.loads(sys.argv[1]); w.append([int(sys.argv[2]), float(sys.argv[3])]); print(json.dumps(w))" "$walk" "$pods" "$thr")"
    local decision; decision="$(python3 -c "import sys; sys.path.insert(0,'scripts'); from saturation import step_decision; print(step_decision(float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])))" "$prev_thr" "$thr" "$plateau")"
    case "$decision" in
      error)
        _record "$cells_json" "$sc" "$digest" "$walk" None 0 None False error creation_choke
        return 0 ;;
      plateau)
        # saturated one rung back; confirm the pinned point with `repeats` reps
        local conf_p99; conf_p99="$(_confirm "$fn" "$mode" "$prev_pods" "$repeats")"
        _record "$cells_json" "$sc" "$digest" "$walk" "$prev_pods" "$prev_thr" "$conf_p99" True ok plateau
        return 0 ;;
      continue)
        prev_pods="$pods"; prev_thr="$thr" ;;
    esac
  done
  # ladder exhausted without plateau
  _record "$cells_json" "$sc" "$digest" "$walk" "$prev_pods" "$prev_thr" None False ok ladder_exhausted
}

_confirm() {  # rerun the pinned pods `repeats` times; echo a representative p99 (median)
  local fn="$1" mode="$2" pods="$3" reps="$4" i p99s=""
  for ((i=0;i<reps;i++)); do reset_state "$mode"; read -r _c _t _p99 < <("$fn" "$pods" with_p99 2>/dev/null || echo "0 0 0"); p99s="$p99s $_p99"; done
  echo "$p99s" | tr ' ' '\n' | grep -v '^$' | sort -n | awk '{a[NR]=$1} END{print (NR? a[int((NR+1)/2)] : "None")}'
}

_record() {  # bridge to cells.py
  python3 -c "
import sys; sys.path.insert(0,'scripts')
import cells
pp = None if sys.argv[5]=='None' else int(sys.argv[5])
p99 = None if sys.argv[7]=='None' else float(sys.argv[7])
cells.record(sys.argv[1], int(sys.argv[2]), image_digest=sys.argv[3],
  walk=__import__('json').loads(sys.argv[4]), pinned_pods=pp, throughput=float(sys.argv[6]),
  p99=p99, saturated=(sys.argv[8]=='True'), status=sys.argv[9], reason=sys.argv[10])
" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}"
}
```

Note: the test overrides `measure_pods` and `reset_state`, so only the walk logic is exercised. **p99 sourcing:** in production `_confirm` re-runs the pinned pods `repeats` times (median throughput is the pinned number) and reads p99 from the pinned run's `merged.json` via the **same p99_ms extraction `gke-bench.sh` already uses** (`run_one`'s p99 parse) — do not invent a new parser. The mock measure fn returns no `merged.json`, so p99 falls back to `None`; the test asserts only the plateau/pin logic (throughput, reason, pinned_pods), which is the part being verified here.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/lib-saturate_test.sh`
Expected: `PASS walk_cell plateau`

- [ ] **Step 5: Add a ladder-exhausted test case**

Append to `scripts/lib-saturate_test.sh` before the final line:
```bash
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
```

- [ ] **Step 6: Run both cases**

Run: `bash scripts/lib-saturate_test.sh`
Expected: `PASS walk_cell plateau` then `PASS walk_cell ladder_exhausted`

- [ ] **Step 7: Commit**

```bash
git add scripts/lib-saturate.sh scripts/lib-saturate_test.sh
git commit -m "bench: saturation walker (per-stream-count ladder, plateau-pin, resumable)"
```

---

### Task 6: Driver (`scripts/bench`)

**Files:**
- Create: `scripts/bench`
- Test: `scripts/bench_test.sh`

**Interfaces:**
- Consumes: `walk_cell` (Task 5), `Suite` (Task 1), `cells.py status_of` (Task 3), `cluster-up.sh`.
- Produces: CLI `scripts/bench <suite.json> {run|report|teardown}`.
  - `run`: for each mode → ensure cluster (records it in `.bench-state/<suite>.json`) → for each stream_count, skip if `status_of`=="saturated", else `walk_cell`. Modes run in parallel, each with `KUBECONFIG=.bench-state/kc-<mode>`.
  - `report`: invoke `scripts/report.py <suite.json>`.
  - `teardown`: read `.bench-state/<suite>.json`, delete only those clusters.

- [ ] **Step 1: Write the failing test**

`scripts/bench_test.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Usage / dispatch
out="$(scripts/bench 2>&1 || true)"
echo "$out" | grep -qi "usage" || { echo "FAIL: no usage on no args"; exit 1; }

# teardown reads only the suite's recorded clusters (dry-run)
mkdir -p .bench-state
echo '{"clusters":[{"name":"bench-wal","zone":"europe-west4-a"}]}' > .bench-state/write-throughput.json
out="$(BENCH_DRYRUN=1 scripts/bench suites/write-throughput.json teardown)"
echo "$out" | grep -q "clusters delete bench-wal" || { echo "FAIL: teardown wrong cluster"; exit 1; }
echo "$out" | grep -q "bench-ursula" && { echo "FAIL: teardown touched a cluster it didn't create"; exit 1; }
rm -f .bench-state/write-throughput.json
echo "PASS bench dispatch+teardown"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/bench_test.sh`
Expected: FAIL — `scripts/bench: No such file or directory`

- [ ] **Step 3: Write the implementation**

`scripts/bench`:
```bash
#!/usr/bin/env bash
# bench <suite.json> {run|report|teardown} — declarative write-throughput suite.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO_ROOT"

usage() { echo "usage: scripts/bench <suite.json> {run|report|teardown}" >&2; exit 2; }
[ $# -lt 2 ] && usage
SUITE_FILE="$1"; CMD="$2"
[ -f "$SUITE_FILE" ] || { echo "no such suite: $SUITE_FILE" >&2; exit 2; }
export SUITE_FILE
SUITE_NAME="$(python3 -c "import sys;sys.path.insert(0,'scripts');from suite import Suite;print(Suite.load('$SUITE_FILE').name)")"
STATE=".bench-state/${SUITE_NAME}.json"; mkdir -p .bench-state
RUN="${BENCH_DRYRUN:+echo}"

_suite() { python3 -c "import sys;sys.path.insert(0,'scripts');from suite import Suite;s=Suite.load('$SUITE_FILE');print($1)"; }

cmd_teardown() {
  [ -f "$STATE" ] || { echo "no clusters recorded for $SUITE_NAME"; return 0; }
  python3 -c "import json;[print(c['name'],c['zone']) for c in json.load(open('$STATE'))['clusters']]" \
    | while read -r name zone; do
        $RUN gcloud container clusters delete "$name" --zone "$zone" --quiet
      done
}

cmd_report() { python3 scripts/report.py "$SUITE_FILE"; }

cmd_run() {
  local modes; modes="$(_suite "' '.join(s.modes)")"
  for mode in $modes; do ( run_mode "$mode" ) & done
  wait
  cmd_report
}

run_mode() {
  local mode="$1" cluster="bench-${mode}"
  export KUBECONFIG="$REPO_ROOT/.bench-state/kc-${mode}"
  # zone per mode: a/b/c within region
  local region; region="$(_suite 's.cluster["region"]')"
  local zoneidx; case "$mode" in wal) zoneidx=a;; ursula) zoneidx=b;; s2) zoneidx=c;; *) zoneidx=a;; esac
  local zone="${region}-${zoneidx}"
  # ensure cluster + record it
  CLUSTER="$cluster" ZONE="$zone" SERVER_MACHINE="$(_suite 's.cluster["server_machine"]')" \
    CLIENT_MACHINE="$(_suite 's.cluster["client_machine"]')" CLIENT_NODES="$(_suite 's.cluster["client_nodes"]')" \
    DS_TARGET=remote bash scripts/cluster-up.sh
  _record_cluster "$cluster" "$zone"
  # deploy + walk
  . scripts/lib-saturate.sh
  export KCTX="gke_$(gcloud config get-value project 2>/dev/null)_${zone}_${cluster}"
  local digest; digest="$(server_image_digest "$mode")"
  local cells_json="results/${SUITE_NAME}/${mode}/cells.json"
  deploy_mode "$mode"
  for sc in $(_suite "' '.join(map(str,s.stream_counts))"); do
    local st; st="$(python3 -c "import sys;sys.path.insert(0,'scripts');import cells;print(cells.status_of('$cells_json',$sc,'$digest'))")"
    [ "$st" = "saturated" ] && { echo "[$mode $sc] already saturated, skip"; continue; }
    walk_cell "$mode" "$sc" "$cells_json" "$digest"
  done
}

_record_cluster() {  # idempotent append to the suite state file
  python3 -c "
import json,os
p='$STATE'; d=json.load(open(p)) if os.path.exists(p) else {'clusters':[]}
if not any(c['name']=='$1' for c in d['clusters']): d['clusters'].append({'name':'$1','zone':'$2'})
json.dump(d, open(p,'w'), indent=2)"
}

case "$CMD" in
  run) cmd_run ;;
  report) cmd_report ;;
  teardown) cmd_teardown ;;
  *) usage ;;
esac
```

Note: `deploy_mode`, `server_image_digest` are thin helpers — `deploy_mode <mode>` reuses the existing `deploy_system`/`deploy_server` switch from `gke-bench.sh` (extract the per-mode flag block into `lib-bench.sh` as `deploy_mode <mode>` in this task). `server_image_digest <mode>` returns the 12-char digest of the deployed server image (do NOT reference the dropped `pins.py`):
```bash
server_image_digest() {  # echo 12-char digest of the deployed server image
  local dep; case "$1" in wal) dep=durable-streams;; ursula) dep=ursula;; s2) dep=s2;; esac
  kubectl --context "$KCTX" -n ds-bench get "deploy/$dep" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' | sha256sum | cut -c1-12
}
```

- [ ] **Step 4: Make it executable + run the test**

Run: `chmod +x scripts/bench && bash scripts/bench_test.sh`
Expected: `PASS bench dispatch+teardown`

- [ ] **Step 5: Commit**

```bash
git add scripts/bench scripts/bench_test.sh scripts/lib-bench.sh
git commit -m "bench: bench driver (run/report/teardown, per-mode parallel, resumable, cluster state file)"
```

---

### Task 7: Report generator

**Files:**
- Create: `scripts/report.py`
- Test: `scripts/report_test.py`

**Interfaces:**
- Consumes: per-mode `cells.json` (Task 3), `Suite` (Task 1).
- Produces: `build(suite_path, results_root) -> (aggregate_rows:list[dict], report_md:str)`; CLI `python3 report.py <suite.json>` writes `results/<suite>/aggregate.csv`, `aggregate.json`, `report.md`.

- [ ] **Step 1: Write the failing test**

`scripts/report_test.py`:
```python
import os, json, tempfile, report

def _setup():
    root = tempfile.mkdtemp()
    for mode, sc, thr, sat in [("wal",1000,510000,True),("wal",100000,0,False),
                               ("ursula",1000,62000,True)]:
        d = os.path.join(root, mode); os.makedirs(d, exist_ok=True)
        status = "error" if (mode=="wal" and sc==100000) else "ok"
        json.dump({"cells":{str(sc):{"stream_count":sc,"throughput":thr,"p99":2.0,
            "pinned_pods":16,"saturated":sat,"status":status,"reason":"plateau",
            "walk":[[16,thr]],"image_digest":"x"}}}, open(os.path.join(d,"cells.json"),"w"))
    return root

def test_aggregate_rows():
    root = _setup()
    suite = os.path.join(os.path.dirname(__file__),"..","suites","write-throughput.json")
    rows, md = report.build(suite, root)
    wal1k = [r for r in rows if r["mode"]=="wal" and r["stream_count"]==1000][0]
    assert wal1k["throughput"] == 510000 and wal1k["saturated"] is True
    err = [r for r in rows if r["mode"]=="wal" and r["stream_count"]==100000][0]
    assert err["status"] == "error"

def test_markdown_has_table_and_headers():
    root = _setup()
    suite = os.path.join(os.path.dirname(__file__),"..","suites","write-throughput.json")
    _, md = report.build(suite, root)
    assert "| stream" in md.lower() or "| streams" in md.lower()
    assert "## Findings" in md and "## Caveats" in md
    assert "ERROR" in md  # the choked 100k cell is flagged, not shown as a real number
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd scripts && python3 -m pytest report_test.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'report'`

- [ ] **Step 3: Write the implementation**

`scripts/report.py`:
```python
"""Aggregate per-mode cells.json into aggregate.csv/json + a markdown skeleton.
Deterministic; no cluster needed."""
import sys, os, json, csv
sys.path.insert(0, os.path.dirname(__file__))
from suite import Suite
import cells as cells_mod

def build(suite_path, results_root):
    s = Suite.load(suite_path)
    rows = []
    for mode in s.modes:
        p = os.path.join(results_root, mode, "cells.json")
        if not os.path.exists(p):
            continue
        for c in cells_mod.all_cells(p):
            rows.append({"mode": mode, "stream_count": c["stream_count"],
                         "pods": c.get("pinned_pods"), "throughput": c.get("throughput"),
                         "p99": c.get("p99"), "saturated": c.get("saturated"),
                         "status": c.get("status"), "reason": c.get("reason"),
                         "walk": c.get("walk")})
    rows.sort(key=lambda r: (r["stream_count"], r["mode"]))
    return rows, _markdown(s, rows)

def _cell_str(r):
    if r["status"] == "error":
        return f"ERROR ({r['reason']})"
    n = r["throughput"]
    mark = "" if r["saturated"] else "†"   # † = not saturated (lower bound)
    return f"{n/1000:.0f}k{mark}"

def _markdown(s, rows):
    out = [f"# {s.name} — write-throughput report", ""]
    out += ["## Throughput at saturation (ops/s)", ""]
    header = "| streams | " + " | ".join(s.modes) + " |"
    out += [header, "|" + "---|"*(len(s.modes)+1)]
    by = {(r["mode"], r["stream_count"]): r for r in rows}
    for sc in s.stream_counts:
        cells_row = [ _cell_str(by[(m, sc)]) if (m, sc) in by else "—" for m in s.modes ]
        out.append(f"| {sc} | " + " | ".join(cells_row) + " |")
    out += ["", "† = not saturated (ladder exhausted) — treat as a lower bound.", ""]
    out += ["## Saturation walks (pods → ops/s)", ""]
    for r in rows:
        walk = " → ".join(f"{p}:{t/1000:.0f}k" for p, t in (r["walk"] or []))
        out.append(f"- **{r['mode']} {r['stream_count']}**: {walk}  (pinned {r['pods']}, {r['reason']})")
    out += ["", "## Findings", "", "_TODO: written by hand on top of the generated data._", ""]
    out += ["## Caveats", "", "_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._", ""]
    return "\n".join(out)

def main():
    suite_path = sys.argv[1]
    s = Suite.load(suite_path)
    root = os.path.join("results", s.name)
    rows, md = build(suite_path, root)
    os.makedirs(root, exist_ok=True)
    with open(os.path.join(root, "aggregate.json"), "w") as f:
        json.dump(rows, f, indent=2)
    with open(os.path.join(root, "aggregate.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["mode","stream_count","pods","throughput","p99","saturated","status","reason"])
        w.writeheader()
        for r in rows: w.writerow({k: r[k] for k in w.fieldnames})
    with open(os.path.join(root, "report.md"), "w") as f:
        f.write(md)
    print(f"wrote {root}/aggregate.csv, aggregate.json, report.md")

if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd scripts && python3 -m pytest report_test.py -v`
Expected: PASS (2 passed)

- [ ] **Step 5: Commit**

```bash
git add scripts/report.py scripts/report_test.py
git commit -m "bench: report generator (aggregate.csv/json + markdown skeleton)"
```

---

### Task 8: Runbook

**Files:**
- Create: `docs/RUNBOOK.md`

- [ ] **Step 1: Write the runbook**

`docs/RUNBOOK.md`:
```markdown
# Benchmark Runbook (write-throughput saturation suite)

## Prerequisites
- `gcloud` authenticated to project `vaxine`; `kubectl`, `python3`, `pytest`.
- Server + ds-bench images built and pushed (see BENCHMARKING.md).

## 1. Edit the suite
`suites/write-throughput.json` declares modes, stream-counts, the per-stream-count
`pod_ladder`, and cluster machine types. The ladder's first rung is the seed; the
last is the climb ceiling.

## 2. Run (idempotent + resumable)
    scripts/bench suites/write-throughput.json run
- Brings up one **persistent** cluster per mode (`bench-wal`/`bench-ursula`/`bench-s2`),
  in zones a/b/c, each with its own KUBECONFIG. Modes run in parallel.
- For each (mode, stream-count) it ramps pods up the ladder until throughput plateaus
  (<`plateau_pct`), pins + confirms with `repeats` reps. CPU is a secondary signal for
  wal only (ursula/s2 have no cpu_pct).
- State + results: `results/<suite>/<mode>/cells.json`. Re-running **skips saturated
  cells**, **resumes** ladder-exhausted ones (extend that stream-count's ladder upward
  in the JSON first), and **re-runs** cells whose server image digest changed.

## 3. Parallelization strategy
- Parallelism is **by mode** (separate clusters). A finished mode is never re-run.
- Within a mode, cells run sequentially (one server at a time per cluster).
- If one mode's cluster fails, the others continue; re-run `bench … run` to resume.

## 4. Known issues
- **100k creation-choke:** ~200–300 concurrent pods can break `PUT /v1/stream`; such
  cells are recorded `status:error` (never a fake ceiling) and flagged in the report.
- **s2** state lives in MinIO — its reset empties the bucket as well as restarting the pod.

## 5. Report
    scripts/bench suites/write-throughput.json report
Writes `results/<suite>/aggregate.{csv,json}` + `report.md` (tables + per-cell saturation
walks + empty Findings/Caveats for you to write the narrative). Regenerable any time.

## 6. Teardown (deferred — explicit)
    scripts/bench suites/write-throughput.json teardown
Deletes **only** the clusters this suite created (tracked in `.bench-state/<suite>.json`).
Clusters otherwise persist between experiments.
```

- [ ] **Step 2: Verify the runbook commands match the script interfaces**

Run: `grep -o 'scripts/bench [^`]*' docs/RUNBOOK.md`
Expected: every invocation is `scripts/bench suites/write-throughput.json {run|report|teardown}` — matching Task 6's CLI.

- [ ] **Step 3: Commit**

```bash
git add docs/RUNBOOK.md
git commit -m "docs: benchmark runbook (saturation suite — run/resume/report/teardown)"
```

---

## Notes for the implementer

- **Reuse, don't rewrite** the engine: `_run_cell_one`, `deploy_server`, `run_fleet_and_coordinator`, `collect_sidecar`, HDR-merge in `lib-bench.sh` are stable. The walker calls them; do not reimplement them.
- **`deploy_mode <mode>`** (used in Task 6) should be extracted from the existing `deploy_system` switch in `gke-bench.sh` — for `wal` inject `--durability wal --wal-shards 4`; for `ursula`/`s2` use their manifests. Keep it in `lib-bench.sh` so both the old `gke-bench.sh` (still used for SSE/replay) and the new `bench` can call it.
- **Do not touch the SSE/replay paths** in `gke-bench.sh` — they remain the mechanism for those test classes (replay's `thr=0` is expected, latency-only).
- Run the full test suite before the final commit: `cd scripts && python3 -m pytest -v` and `for t in scripts/*_test.sh; do bash "$t"; done`.
```
