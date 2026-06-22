# Calibrate-then-pin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the CPU-only headroom bump loop with a calibrate-then-pin workflow: a calibration finds the saturating pod-count per cell (CPU **or** throughput-plateau), pins it keyed by server-image+machine+cpu/mem in a committed `calibration/pins.json`, and measurement runs at the fixed pin × REPEATS.

**Architecture:** Testable logic lives in two stdlib-python modules (`scripts/pins.py`, `scripts/saturation.py`); `scripts/lib-bench.sh:run_cell` becomes a thin `MODE`-aware orchestrator that shells out to them. Phase scripts (`gke-rawpower.sh`/`gke-scaleout.sh`/`gke-sustained.sh`) are unchanged.

**Tech Stack:** Bash (harness), Python 3 stdlib (`json`/`argparse`/`unittest` — **no pytest available**), kubectl, existing `render_common.py`.

**Spec:** `docs/superpowers/specs/2026-06-22-calibrate-then-pin-design.md`

## Global Constraints

- Python: **stdlib only** (no pytest/pip). Tests are `unittest`, run with `python3 scripts/<name>_test.py`.
- Tests set `PINS_PATH` env to a temp file; never touch the real `calibration/pins.json`.
- `pins.json` written with `json.dump(..., indent=2, sort_keys=True)` + trailing newline (clean diffs). Recency is the integer `seq` field, never file order or timestamps.
- Saturation rule (verbatim): `server_bound` if `cpu_pct ≥ 0.90 × cores × 100` **OR** (`prev_thr > 0` and `(thr-prev_thr)/prev_thr < 0.10`); pin the **knee** = pre-doubling pods on plateau, current pods on cpu.
- Calibration key string: `"<digest12>-<machine>-cpu<N>-mem<M>"`; `digest12` = first 12 hex chars of the image's `sha256:` digest.
- `MODE` default = `measure`. `MODE=calibrate` forces `REPEATS=1` unless already overridden.
- No code change may make a `kubectl` failure fatal under `set -e` in the collect path.

---

### Task 1: `pins.py` — key construction, get, set

**Files:**
- Create: `scripts/pins.py`
- Create: `scripts/pins_test.py`
- Create: `calibration/pins.json` (content: `{}\n`)

**Interfaces:**
- Produces (CLI):
  - `pins.py key --image <ref> --machine <m> --cpu <n> --mem <x>` → prints key, exit 0
  - `pins.py get <key> <cell>` → prints pods (int), exit 0; exit 1 if key/cell absent
  - `pins.py set <key> <cell> <pods> --reason R [--saturated true|false] [--ops N] [--image .. --machine .. --cpu .. --mem ..]`
  - Path from `--path` or `$PINS_PATH`, default `<repo>/calibration/pins.json`
- Produces (python): `digest12(image)->str`, `make_key(image,machine,cpu,mem)->str`

- [ ] **Step 1: Write the failing test** — `scripts/pins_test.py`

```python
import json, os, subprocess, sys, tempfile, unittest
HERE = os.path.dirname(os.path.abspath(__file__))
PINS = os.path.join(HERE, "pins.py")

def run(args, path):
    env = dict(os.environ, PINS_PATH=path)
    return subprocess.run([sys.executable, PINS, *args], env=env,
                          capture_output=True, text=True)

class TestKeyGetSet(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(suffix=".json", delete=False).name
        open(self.tmp, "w").write("{}\n")
    def tearDown(self):
        os.unlink(self.tmp)

    def test_key_from_full_imageid(self):
        r = run(["key", "--image",
                 "europe-west1-docker.pkg.dev/x/ds-bench/durable-streams@sha256:c105b202e5b31b67aa",
                 "--machine", "c4d-standard-16-lssd", "--cpu", "4", "--mem", "16Gi"], self.tmp)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "c105b202e5b3-c4d-standard-16-lssd-cpu4-mem16Gi")

    def test_get_missing_exits_1(self):
        r = run(["get", "nokey", "nocell"], self.tmp)
        self.assertEqual(r.returncode, 1)

    def test_set_then_get_roundtrip(self):
        run(["set", "K", "ms-cpu4-n10", "16", "--reason", "plateau", "--ops", "860827",
             "--image", "sha256:abc", "--machine", "m", "--cpu", "4", "--mem", "16Gi"], self.tmp)
        r = run(["get", "K", "ms-cpu4-n10"], self.tmp)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.strip(), "16")
        data = json.load(open(self.tmp))
        self.assertEqual(data["K"]["cells"]["ms-cpu4-n10"]["reason"], "plateau")
        self.assertEqual(data["K"]["seq"], 1)

    def test_set_preserves_other_keys(self):
        run(["set", "A", "c", "8", "--reason", "cpu"], self.tmp)
        run(["set", "B", "c", "8", "--reason", "cpu"], self.tmp)
        data = json.load(open(self.tmp))
        self.assertIn("A", data); self.assertIn("B", data)
        self.assertEqual(data["B"]["seq"], 2)

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 scripts/pins_test.py -v`
Expected: FAIL (`pins.py` does not exist → non-zero returncodes / errors).

- [ ] **Step 3: Write minimal implementation** — `scripts/pins.py`

```python
#!/usr/bin/env python3
"""calibration/pins.json CRUD + key construction (calibrate-then-pin)."""
import argparse, json, os, re, sys

_REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_PATH = os.path.join(_REPO, "calibration", "pins.json")

def _path(args):
    return args.path or os.environ.get("PINS_PATH") or DEFAULT_PATH

def _load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}

def _save(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")

def digest12(image):
    m = re.search(r'sha256:([0-9a-f]{12,})', image) or re.search(r'([0-9a-f]{12,})', image)
    if not m:
        sys.exit(f"cannot extract digest from image ref: {image!r}")
    return m.group(1)[:12]

def make_key(image, machine, cpu, mem):
    return f"{digest12(image)}-{machine}-cpu{cpu}-mem{mem}"

def cmd_key(a):
    print(make_key(a.image, a.machine, a.cpu, a.mem))

def cmd_get(a):
    e = _load(_path(a)).get(a.key)
    if not e or a.cell not in e.get("cells", {}):
        sys.exit(1)
    print(e["cells"][a.cell]["pods"])

def cmd_set(a):
    path = _path(a); data = _load(path); e = data.get(a.key)
    if e is None:
        seq = 1 + max((v.get("seq", 0) for v in data.values()), default=0)
        e = {"seq": seq, "image": a.image or "", "machine": a.machine or "",
             "server_cpu": a.cpu or "", "server_mem": a.mem or "", "cells": {}}
        data[a.key] = e
    cell = {"pods": a.pods, "saturated": a.saturated, "reason": a.reason}
    if a.ops is not None:
        cell["ops"] = a.ops
    e["cells"][a.cell] = cell
    _save(path, data)

def _bool(x):
    return str(x).lower() == "true"

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--path", default=None)
    sub = p.add_subparsers(dest="cmd", required=True)
    k = sub.add_parser("key")
    for f in ("image", "machine", "cpu", "mem"):
        k.add_argument("--" + f, required=True)
    k.set_defaults(func=cmd_key)
    g = sub.add_parser("get"); g.add_argument("key"); g.add_argument("cell"); g.set_defaults(func=cmd_get)
    s = sub.add_parser("set")
    s.add_argument("key"); s.add_argument("cell"); s.add_argument("pods", type=int)
    s.add_argument("--reason", required=True)
    s.add_argument("--saturated", type=_bool, default=True)
    s.add_argument("--ops", type=int, default=None)
    for f in ("image", "machine", "cpu", "mem"):
        s.add_argument("--" + f, default=None)
    s.set_defaults(func=cmd_set)
    a = p.parse_args(); a.func(a)

if __name__ == "__main__":
    main()
```

Also create `calibration/pins.json` containing exactly:
```json
{}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 scripts/pins_test.py -v`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/pins.py scripts/pins_test.py calibration/pins.json
git commit -m "feat(calib): pins.py key/get/set + empty pins.json"
```

---

### Task 2: `pins.py` — `latest` and `list`

**Files:**
- Modify: `scripts/pins.py`
- Modify: `scripts/pins_test.py`

**Interfaces:**
- Produces (CLI): `pins.py latest <machine> <cpu> <mem>` → prints key with highest `seq` whose machine+cpu+mem match (digest ignored); exit 1 if none. `pins.py list` → human summary.

- [ ] **Step 1: Write the failing test** — append to `scripts/pins_test.py`

```python
class TestLatest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(suffix=".json", delete=False).name
        open(self.tmp, "w").write("{}\n")
    def tearDown(self):
        os.unlink(self.tmp)

    def test_latest_picks_highest_seq_matching(self):
        run(["set", "old-m-cpu4-mem16Gi", "c", "8", "--reason", "cpu",
             "--machine", "m", "--cpu", "4", "--mem", "16Gi"], self.tmp)
        run(["set", "new-m-cpu4-mem16Gi", "c", "16", "--reason", "cpu",
             "--machine", "m", "--cpu", "4", "--mem", "16Gi"], self.tmp)
        run(["set", "other-z-cpu8-mem16Gi", "c", "4", "--reason", "cpu",
             "--machine", "z", "--cpu", "8", "--mem", "16Gi"], self.tmp)
        r = run(["latest", "m", "4", "16Gi"], self.tmp)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.strip(), "new-m-cpu4-mem16Gi")

    def test_latest_none_exits_1(self):
        r = run(["latest", "nope", "4", "16Gi"], self.tmp)
        self.assertEqual(r.returncode, 1)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 scripts/pins_test.py -v`
Expected: FAIL (`latest` subcommand unknown → argparse error, returncode 2).

- [ ] **Step 3: Write minimal implementation** — add to `scripts/pins.py` before `main()`:

```python
def cmd_latest(a):
    data = _load(_path(a))
    m = [(v.get("seq", 0), k) for k, v in data.items()
         if v.get("machine") == a.machine and v.get("server_cpu") == a.cpu
         and v.get("server_mem") == a.mem]
    if not m:
        sys.exit(1)
    print(max(m)[1])

def cmd_list(a):
    data = _load(_path(a))
    for k in sorted(data, key=lambda k: data[k].get("seq", 0)):
        e = data[k]
        print(f"[seq {e.get('seq')}] {k}  ({len(e.get('cells', {}))} cells)")
```

And register them inside `main()` (after the `set` parser):

```python
    la = sub.add_parser("latest")
    la.add_argument("machine"); la.add_argument("cpu"); la.add_argument("mem")
    la.set_defaults(func=cmd_latest)
    li = sub.add_parser("list"); li.set_defaults(func=cmd_list)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 scripts/pins_test.py -v`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/pins.py scripts/pins_test.py
git commit -m "feat(calib): pins.py latest/list (reuse selector by seq)"
```

---

### Task 3: `saturation.py` — classifier + throughput reader

**Files:**
- Create: `scripts/saturation.py`
- Create: `scripts/saturation_test.py`

**Interfaces:**
- Produces (python): `classify(prev_thr, thr, cpu_pct, cores, cpu_frac=0.90, plateau_frac=0.10) -> {"cpu","plateau","headroom"}`; `extract_throughput(path) -> float`
- Produces (CLI): `saturation.py --merged <file> --prev-thr <P> --cpu <C> --cores <N>` → prints `<reason> <thr>` (space-separated).

- [ ] **Step 1: Write the failing test** — `scripts/saturation_test.py`

```python
import json, os, tempfile, unittest
import importlib.util
HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("saturation", os.path.join(HERE, "saturation.py"))
sat = importlib.util.module_from_spec(spec); spec.loader.exec_module(sat)

class TestClassify(unittest.TestCase):
    def test_cpu_bound(self):          # 370% >= 0.9*4*100=360
        self.assertEqual(sat.classify(0, 100000, 370.0, 4), "cpu")
    def test_headroom_real_n10_to_n100(self):   # +24% gain, cpu under threshold
        self.assertEqual(sat.classify(860827, 1069919, 222.0, 4), "headroom")
    def test_plateau_small_gain(self):          # +5% gain, cpu low
        self.assertEqual(sat.classify(1000000, 1050000, 200.0, 4), "plateau")
    def test_no_prev_cannot_plateau(self):
        self.assertEqual(sat.classify(0, 50, 10.0, 4), "headroom")

class TestThroughput(unittest.TestCase):
    def test_reads_aggregate_ops(self):
        p = tempfile.NamedTemporaryFile(suffix=".json", delete=False, mode="w")
        p.write('coordinator log line\n{"aggregate_ops_per_sec": 1069919.5, "p99_ms": 12.7}\n'); p.close()
        self.assertAlmostEqual(sat.extract_throughput(p.name), 1069919.5)
        os.unlink(p.name)
    def test_reads_aggregate_events(self):
        p = tempfile.NamedTemporaryFile(suffix=".json", delete=False, mode="w")
        p.write('{"aggregate_events_per_sec": 120000.0}\n'); p.close()
        self.assertAlmostEqual(sat.extract_throughput(p.name), 120000.0)
        os.unlink(p.name)

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 scripts/saturation_test.py -v`
Expected: FAIL (`saturation.py` missing).

- [ ] **Step 3: Write minimal implementation** — `scripts/saturation.py`

```python
#!/usr/bin/env python3
"""Pure saturation classifier + throughput reader for the calibration bump loop."""
import argparse, json, re, sys

def classify(prev_thr, thr, cpu_pct, cores, cpu_frac=0.90, plateau_frac=0.10):
    if cpu_pct >= cpu_frac * cores * 100.0:
        return "cpu"
    if prev_thr > 0 and (thr - prev_thr) / prev_thr < plateau_frac:
        return "plateau"
    return "headroom"

def extract_throughput(path):
    """Last JSON object in merged.json → aggregate_ops_per_sec or _events_per_sec, else 0.0."""
    try:
        text = open(path).read()
    except FileNotFoundError:
        return 0.0
    obj = None
    for m in re.finditer(r'\{.*\}', text):
        try:
            obj = json.loads(m.group(0))
        except json.JSONDecodeError:
            continue
    if not obj:
        return 0.0
    for k in ("aggregate_ops_per_sec", "aggregate_events_per_sec"):
        if k in obj:
            return float(obj[k])
    return 0.0

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--merged", required=True)
    p.add_argument("--prev-thr", type=float, default=0.0)
    p.add_argument("--cpu", type=float, required=True)
    p.add_argument("--cores", type=float, required=True)
    a = p.parse_args()
    thr = extract_throughput(a.merged)
    print(f"{classify(a.prev_thr, thr, a.cpu, a.cores)} {thr}")

if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 scripts/saturation_test.py -v`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/saturation.py scripts/saturation_test.py
git commit -m "feat(calib): saturation classifier (cpu|plateau|headroom) + throughput reader"
```

---

### Task 4: `lib-bench.sh` — robust coordinator-merged fetch (race fix)

**Files:**
- Modify: `scripts/lib-bench.sh` (add `fetch_coordinator_merged`; replace the `K logs job/bench-coordinator > merged.json` line in `run_cell`)

**Interfaces:**
- Produces: `fetch_coordinator_merged DEST` — writes coordinator stdout to `DEST`, retrying while the pod is `ContainerCreating`; never returns non-zero.

- [ ] **Step 1: Add the function** — in `scripts/lib-bench.sh`, immediately after the `run_fleet_and_coordinator() { ... }` definition, add:

```bash
# fetch_coordinator_merged DEST — pull coordinator stdout into DEST. Retries while
# the pod is still ContainerCreating (kubectl logs returns BadRequest then). Never
# fatal: on persistent failure writes an error marker so `set -e` can't abort.
fetch_coordinator_merged() {
  local dest="$1" i out
  for i in $(seq 1 30); do
    if out="$(K logs job/bench-coordinator 2>/dev/null)" && [ -n "$out" ]; then
      printf '%s\n' "$out" > "$dest"
      return 0
    fi
    sleep 2
  done
  echo '{"error":"coordinator logs unavailable after retries"}' > "$dest"
  echo "    WARN: coordinator logs unavailable after retries → wrote error marker"
}
```

- [ ] **Step 2: Replace the fragile fetch** — in `run_cell`, replace this line:

```bash
      K logs job/bench-coordinator > "${cell_dir}/merged.json"
```

with:

```bash
      fetch_coordinator_merged "${cell_dir}/merged.json"
```

- [ ] **Step 3: Verify the script still parses**

Run: `bash -n scripts/lib-bench.sh && echo OK`
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add scripts/lib-bench.sh
git commit -m "fix(harness): retry coordinator log fetch (kills ContainerCreating race that aborted runs)"
```

---

### Task 5: `lib-bench.sh` — calibration key helper

**Files:**
- Modify: `scripts/lib-bench.sh` (add `server_calibration_key`)

**Interfaces:**
- Consumes: `pins.py key` (Task 1); `server_label` (existing); env `SERVER_MACHINE`, `SERVER_CPUS`, `SERVER_MEM`, `REPO_ROOT`.
- Produces: `server_calibration_key` → prints `<digest12>-<machine>-cpu<N>-mem<M>` for the running server pod.

- [ ] **Step 1: Add the helper** — in `scripts/lib-bench.sh`, after the `collect_sidecar()` definition, add:

```bash
# server_calibration_key — calibration key for the CURRENTLY RUNNING server pod:
# <image-digest12>-<machine>-cpu<cpus>-mem<mem>. Machine is "kind" when unset (local).
server_calibration_key() {
  local img machine
  img="$(K get pod -l "$(server_label)" -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' 2>/dev/null)"
  machine="${SERVER_MACHINE:-kind}"
  python3 "${REPO_ROOT}/scripts/pins.py" key --image "$img" \
    --machine "$machine" --cpu "$SERVER_CPUS" --mem "$SERVER_MEM"
}
```

- [ ] **Step 2: Verify parse + key format with a stubbed imageID**

Run:
```bash
bash -n scripts/lib-bench.sh && echo OK
python3 scripts/pins.py key --image \
  "reg/durable-streams@sha256:c105b202e5b31b67aabb" \
  --machine c4d-standard-16-lssd --cpu 4 --mem 16Gi
```
Expected: `OK` then `c105b202e5b3-c4d-standard-16-lssd-cpu4-mem16Gi`

- [ ] **Step 3: Commit**

```bash
git add scripts/lib-bench.sh
git commit -m "feat(calib): server_calibration_key helper (digest+machine+cpu+mem)"
```

---

### Task 6: `lib-bench.sh` — `run_cell` calibrate path

**Files:**
- Modify: `scripts/lib-bench.sh` (`run_cell`: branch on `MODE`; calibrate = bump loop using `saturation.py`, pin the knee via `pins.py set`)

**Interfaces:**
- Consumes: `saturation.py` (Task 3), `pins.py set` (Task 1), `server_calibration_key` (Task 5), `fetch_coordinator_merged` (Task 4).
- Produces: writes a pin per cell into `calibration/pins.json`; persists `verdict.txt` with `reason`/`saturated`.

- [ ] **Step 1: Gate calibrate REPEATS** — near the top of `run_cell`, after `local cell_name=...`, add:

```bash
  local MODE="${MODE:-measure}"
  if [ "$MODE" = "calibrate" ]; then REPEATS=1; fi
```

- [ ] **Step 2: Replace the bump loop body with a mode switch.** Replace the entire `for repeat in $(seq 1 "$REPEATS"); do ... done` block in `run_cell` with:

```bash
  local repeat
  for repeat in $(seq 1 "$REPEATS"); do
    local cell_dir="${RESULTS_ROOT}/${cell_name}/rep${repeat}"
    mkdir -p "$cell_dir"

    if [ "$MODE" = "calibrate" ]; then
      _run_cell_calibrate "$cell_name" "$bench_cmd" "$out_prefix" "$merge_cmd" "$cpu_cores" "$cell_dir" "$repeat"
    else
      _run_cell_measure "$cell_name" "$bench_cmd" "$out_prefix" "$merge_cmd" "$cpu_cores" "$cell_dir" "$repeat"
    fi
  done
```

- [ ] **Step 3: Add `_run_cell_one` (single fleet run at a fixed pod count).** Add before `run_cell()`:

```bash
# _run_cell_one CELL BENCH OUTP MERGE POD REPEAT CELLDIR — one fleet+coordinator run
# at PODS pods. Echoes "cpu_pct throughput" on stdout. Writes merged.json/samples.csv.
_run_cell_one() {
  local cell_name="$1" bench_cmd="$2" out_prefix="$3" merge_cmd="$4" pods="$5" repeat="$6" cell_dir="$7"
  RUN_ID="${SWEEP_RUN_ID}-${cell_name}-r${repeat}-p${pods}"
  export PARALLELISM="$pods"
  BENCH_CMD="$bench_cmd"; OUT_PREFIX="$out_prefix"; MERGE_CMD="$merge_cmd"
  reset_sidecar_samples
  run_fleet_and_coordinator
  fetch_coordinator_merged "${cell_dir}/merged.json"
  collect_sidecar "$cell_dir"
  local cpu_pct="0"
  if [ -f "${cell_dir}/samples.csv" ]; then
    cpu_pct="$(compute_server_cpu_pct "${cell_dir}/samples.csv")"
  fi
  local thr
  thr="$(python3 "${REPO_ROOT}/scripts/saturation.py" --merged "${cell_dir}/merged.json" \
          --prev-thr 0 --cpu "$cpu_pct" --cores 1 2>/dev/null | awk '{print $2}')"
  echo "${cpu_pct} ${thr:-0}"
}
```

- [ ] **Step 4: Add `_run_cell_calibrate`.** Add before `run_cell()`:

```bash
# _run_cell_calibrate — bump until saturation_check says cpu/plateau (or caps), pin the knee.
_run_cell_calibrate() {
  local cell_name="$1" bench_cmd="$2" out_prefix="$3" merge_cmd="$4" cpu_cores="$5" cell_dir="$6" repeat="$7"
  local pods="$INIT_PARALLELISM" prev_pods=0 prev_thr=0 bumps=0
  local reason="max_pods" saturated="false" pin_pods="$pods" pin_thr=0
  while true; do
    echo "  [calibrate ${cell_name}] parallelism=${pods}"
    read -r cpu_pct thr < <(_run_cell_one "$cell_name" "$bench_cmd" "$out_prefix" "$merge_cmd" "$pods" "$repeat" "$cell_dir")
    local cls
    cls="$(python3 -c 'import sys,importlib.util,os
s=importlib.util.spec_from_file_location("s",os.path.join(os.environ["REPO_ROOT"],"scripts","saturation.py"))
m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.classify(float(sys.argv[1]),float(sys.argv[2]),float(sys.argv[3]),float(sys.argv[4])))' \
      "$prev_thr" "$thr" "$cpu_pct" "$cpu_cores")"
    echo "    cpu%=${cpu_pct} thr=${thr} class=${cls}"
    if [ "$cls" = "cpu" ]; then
      reason="cpu"; saturated="true"; pin_pods="$pods"; pin_thr="$thr"; break
    elif [ "$cls" = "plateau" ]; then
      reason="plateau"; saturated="true"; pin_pods="$prev_pods"; pin_thr="$prev_thr"; break
    fi
    if [ "$bumps" -ge "$MAX_BUMPS" ] || [ $((pods * 2)) -gt "$MAX_PODS" ]; then
      reason="max_pods"; saturated="false"; pin_pods="$pods"; pin_thr="$thr"; break
    fi
    prev_pods="$pods"; prev_thr="$thr"; bumps=$((bumps + 1)); pods=$((pods * 2))
  done
  local key; key="$(server_calibration_key)"
  python3 "${REPO_ROOT}/scripts/pins.py" set "$key" "$cell_name" "$pin_pods" \
    --reason "$reason" --saturated "$saturated" --ops "${pin_thr%.*}" \
    --image "$(K get pod -l "$(server_label)" -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' 2>/dev/null)" \
    --machine "${SERVER_MACHINE:-kind}" --cpu "$SERVER_CPUS" --mem "$SERVER_MEM"
  { echo "cell=${cell_name}"; echo "mode=calibrate"; echo "parallelism=${pin_pods}";
    echo "server_cpu_cores=${cpu_cores}"; echo "reason=${reason}"; echo "saturated=${saturated}";
    echo "calibration_key=${key}"; } > "${cell_dir}/verdict.txt"
  echo "  calibrated ${cell_name}: pods=${pin_pods} reason=${reason} saturated=${saturated} → ${key}"
}
```

(`REPO_ROOT` is already exported by the phase scripts; the inline `python3 -c` reads it from the environment.)

- [ ] **Step 5: Verify parse**

Run: `bash -n scripts/lib-bench.sh && echo OK`
Expected: `OK`

- [ ] **Step 6: Commit**

```bash
git add scripts/lib-bench.sh
git commit -m "feat(calib): run_cell calibrate mode — bump to knee, pin to pins.json"
```

---

### Task 7: `lib-bench.sh` — `run_cell` measure path (pin/reuse/fail-fast + provenance)

**Files:**
- Modify: `scripts/lib-bench.sh` (add `_run_cell_measure`)

**Interfaces:**
- Consumes: `pins.py get`/`latest` (Tasks 1–2), `server_calibration_key` (Task 5), `_run_cell_one` (Task 6), env `REUSE_CALIBRATION`.
- Produces: fixed-pod run at the pinned count; `verdict.txt` with provenance (`calibration_key`, `calibration_matched`, `reason`, `saturated`).

- [ ] **Step 1: Add `_run_cell_measure`.** Add before `run_cell()`:

```bash
# _run_cell_measure — resolve the pin for this cell (own key, else REUSE=latest, else
# fail fast), run REPEATS-fixed at the pinned pods, record provenance.
_run_cell_measure() {
  local cell_name="$1" bench_cmd="$2" out_prefix="$3" merge_cmd="$4" cpu_cores="$5" cell_dir="$6" repeat="$7"
  local key used_key pin_pods matched="true"
  key="$(server_calibration_key)"
  if pin_pods="$(python3 "${REPO_ROOT}/scripts/pins.py" get "$key" "$cell_name" 2>/dev/null)"; then
    used_key="$key"
  elif [ "${REUSE_CALIBRATION:-}" = "latest" ]; then
    used_key="$(python3 "${REPO_ROOT}/scripts/pins.py" latest "${SERVER_MACHINE:-kind}" "$SERVER_CPUS" "$SERVER_MEM" 2>/dev/null)" \
      || { echo "ERROR: REUSE_CALIBRATION=latest but no calibration for machine=${SERVER_MACHINE:-kind} cpu=${SERVER_CPUS} mem=${SERVER_MEM}" >&2; exit 1; }
    pin_pods="$(python3 "${REPO_ROOT}/scripts/pins.py" get "$used_key" "$cell_name" 2>/dev/null)" \
      || { echo "ERROR: reused calibration ${used_key} has no cell ${cell_name}" >&2; exit 1; }
    matched="false"
    echo "    REUSE: pinning from ${used_key} (image mismatch vs ${key})"
  else
    echo "ERROR: no calibration for ${key} cell ${cell_name}; run MODE=calibrate or set REUSE_CALIBRATION=latest" >&2
    exit 1
  fi

  echo "  [measure ${cell_name}] pinned parallelism=${pin_pods} (matched=${matched})"
  local cpu_pct thr
  read -r cpu_pct thr < <(_run_cell_one "$cell_name" "$bench_cmd" "$out_prefix" "$merge_cmd" "$pin_pods" "$repeat" "$cell_dir")
  { echo "cell=${cell_name}"; echo "mode=measure"; echo "parallelism=${pin_pods}";
    echo "server_cpu_cores=${cpu_cores}"; echo "server_cpu_pct=${cpu_pct}";
    echo "calibration_key=${used_key}"; echo "running_key=${key}";
    echo "calibration_matched=${matched}"; } > "${cell_dir}/verdict.txt"
  echo "  measured ${cell_name}: pods=${pin_pods} cpu%=${cpu_pct} thr=${thr} matched=${matched}"
}
```

- [ ] **Step 2: Verify parse**

Run: `bash -n scripts/lib-bench.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Confirm the dead code is gone.** The old CPU-only loop, `headroom_verdict` calls inside `run_cell`, and the old `verdict.txt` writer were removed in Task 6 Step 2. Verify no stale references:

Run: `grep -n 'MAX_BUMPS reached without saturating\|doubling pods' scripts/lib-bench.sh || echo CLEAN`
Expected: `CLEAN`

- [ ] **Step 4: Commit**

```bash
git add scripts/lib-bench.sh
git commit -m "feat(calib): run_cell measure mode — pinned run, REUSE=latest, fail-fast, provenance"
```

---

### Task 8: Reports — surface cap reason + calibration provenance

**Files:**
- Modify: `scripts/render_common.py` (verdict parsing → expose `reason`, `saturated`, `calibration_matched`)
- Modify: `scripts/gen-report.py` (render a `cap`/`calib` annotation per cell)
- Test: `scripts/render_common_test.py` (new)

**Interfaces:**
- Consumes: `verdict.txt` fields written in Tasks 6–7.
- Produces: `parse_verdict(path) -> dict` including `reason`, `saturated`, `calibration_matched`, `calibration_key`.

- [ ] **Step 1: Write the failing test** — `scripts/render_common_test.py`

```python
import os, tempfile, importlib.util, unittest
HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("rc", os.path.join(HERE, "render_common.py"))
rc = importlib.util.module_from_spec(spec); spec.loader.exec_module(rc)

class TestParseVerdict(unittest.TestCase):
    def _write(self, body):
        p = tempfile.NamedTemporaryFile(suffix=".txt", delete=False, mode="w")
        p.write(body); p.close(); return p.name
    def test_measure_provenance(self):
        f = self._write("cell=ms-cpu4-n10\nmode=measure\nparallelism=16\n"
                        "calibration_matched=false\ncalibration_key=old-key\n")
        v = rc.parse_verdict(f)
        self.assertEqual(v["calibration_matched"], "false")
        self.assertEqual(v["calibration_key"], "old-key")
        os.unlink(f)
    def test_calibrate_reason(self):
        f = self._write("cell=c\nmode=calibrate\nreason=plateau\nsaturated=true\n")
        v = rc.parse_verdict(f)
        self.assertEqual(v["reason"], "plateau")
        os.unlink(f)

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 scripts/render_common_test.py -v`
Expected: FAIL (`parse_verdict` absent, or missing keys).

- [ ] **Step 3: Implement `parse_verdict`** in `scripts/render_common.py`. Add (or extend the existing verdict reader to expose all `key=value` lines):

```python
def parse_verdict(path):
    """Return all key=value lines from a verdict.txt as a dict (str->str)."""
    out = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if "=" in line:
                    k, _, val = line.partition("=")
                    out[k.strip()] = val.strip()
    except FileNotFoundError:
        pass
    return out
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 scripts/render_common_test.py -v`
Expected: PASS (2 tests).

- [ ] **Step 5: Annotate the per-cell string in `gen-report.py`.** The cell text is built by `fmt_cell(a)` (gen-report.py:119-131), which renders `rate · p99 · cpu (par=N)` from the aggregated cell dict `a`. (a) Ensure the cell aggregation that builds `a` carries the verdict fields — wherever the aggregator already reads `verdict.txt` for `parallelism`/`verdict`, also pull `reason` and `calibration_matched` via `parse_verdict` into `a["reason"]` / `a["calibration_matched"]`. (b) Append them in `fmt_cell` just before `return`:

```python
    cap = a.get("reason") or a.get("verdict")
    if cap:
        s += f" · {cap}"
    if a.get("calibration_matched") == "false":
        s += " ⚠reused"
    return s
```

where `s` is the existing `f"{rate:,.0f} {unit} · p99 {p99_s} · cpu {cpu_s} (par={par_s})"` (assign it to `s` instead of returning it directly).

- [ ] **Step 6: Smoke the renderer on existing results**

Run: `python3 scripts/gen-report.py results/scaleout/scaleout-slow-1782133067-64105 2>&1 | head -30`
Expected: renders without error; legacy cells show `cap` from their `verdict=` line and `calib` blank/✓ (no provenance present).

- [ ] **Step 7: Commit**

```bash
git add scripts/render_common.py scripts/render_common_test.py scripts/gen-report.py
git commit -m "feat(report): surface cap reason + calibration provenance per cell"
```

---

### Task 9: Docs + end-to-end local-kind validation

**Files:**
- Modify: `BENCHMARKING.md` (calibrate-then-pin workflow section)
- Modify: `docs/gke-cluster-setup.md` (note the new `MODE`/`REUSE_CALIBRATION` knobs)

- [ ] **Step 1: Document the workflow** — add a section to `BENCHMARKING.md`:

```markdown
## Calibrate-then-pin

The phase runners measure at a **pinned** client pod-count per cell, recorded in
`calibration/pins.json` and keyed by server-image-digest + machine + cpu/mem.

1. After building a new server image, calibrate once:
   `MODE=calibrate DS_TARGET=remote scripts/gke-scaleout.sh slow`
   then `git add calibration/pins.json && git commit`.
2. Measure (default) — pinned, reproducible:
   `DS_TARGET=remote scripts/gke-scaleout.sh slow`
   Fails fast if the running image has no calibration.
3. Reuse a previous image's calibration on a new build:
   `REUSE_CALIBRATION=latest DS_TARGET=remote scripts/gke-scaleout.sh slow`
   Reports flag every cell as `⚠ reused` (image mismatch).

Saturation during calibration = server CPU ≥ 90%×cores **or** <10% throughput gain
on doubling pods; the leanest fleet at ~peak (the knee) is pinned. Reports show the
cap reason (`cpu`/`plateau`/`max_pods`) and whether the calibration matched.
```

- [ ] **Step 2: Note the knobs** — in `docs/gke-cluster-setup.md`, add to the env-knobs guidance:

```markdown
- `MODE=calibrate|measure` (default `measure`) and `REUSE_CALIBRATION=latest`
  control calibrate-then-pin (see BENCHMARKING.md → Calibrate-then-pin).
```

- [ ] **Step 3: Run the full python test suite**

Run:
```bash
for t in scripts/pins_test.py scripts/saturation_test.py scripts/render_common_test.py; do
  echo "== $t =="; python3 "$t" || exit 1
done
echo ALL-GREEN
```
Expected: each test file passes; final `ALL-GREEN`.

- [ ] **Step 4: End-to-end local-kind smoke (calibrate → measure → fail-fast).**

Run (requires a local kind cluster + images per BENCHMARKING.md "local" setup):
```bash
export DS_TARGET=local
scripts/cluster-up.sh && scripts/build-images.sh
# calibrate writes a pin:
MODE=calibrate scripts/gke-scaleout.sh fast
test -s calibration/pins.json && python3 scripts/pins.py list
# measure consumes it (no bumping):
scripts/gke-scaleout.sh fast
# fail-fast proof: a bogus key has no pin →
MODE=measure SERVER_MEM=999Gi scripts/gke-scaleout.sh fast; echo "exit=$?  (expect non-zero: no calibration)"
```
Expected: calibrate prints `calibrated … → <key>` and `pins.py list` shows it; measure prints `measured … matched=true`; the bogus-mem run exits non-zero with the "no calibration … run MODE=calibrate" message.

- [ ] **Step 5: Commit**

```bash
git add BENCHMARKING.md docs/gke-cluster-setup.md
git commit -m "docs(calib): calibrate-then-pin workflow + MODE/REUSE knobs"
```

---

## Self-Review

**Spec coverage:**
- MODE toggle / calibrate / measure → Tasks 6, 7. ✓
- Key = digest+machine+cpu/mem → Tasks 1, 5. ✓
- Single committed `pins.json` → Task 1 (created), all set/get. ✓
- Fail-fast default + REUSE=latest → Task 7. ✓
- Saturation = CPU≥90% OR <10% gain, pin knee → Tasks 3, 6. ✓
- Reports: cap reason + provenance → Task 8. ✓
- Coordinator-fetch race fix → Task 4. ✓
- `seq` recency for `latest` → Tasks 1, 2. ✓
- TDD seeded from real samples (n10/n100) → Task 3 tests. ✓
- Edge cases (max_pods lower-bound, missing samples, reuse-missing) → Tasks 6, 7. ✓

**Placeholder scan:** none — every code step has complete content.

**Type/name consistency:** `pins.py` subcommands (`key/get/set/latest/list`) and `saturation.classify`/`extract_throughput` are used with the same names/args in Tasks 4–8. `server_calibration_key`, `_run_cell_one`, `_run_cell_calibrate`, `_run_cell_measure`, `fetch_coordinator_merged` are defined once and referenced consistently. `verdict.txt` keys written in Tasks 6–7 (`reason`, `saturated`, `calibration_matched`, `calibration_key`) match `parse_verdict` consumption in Task 8.

**Note:** Task 8 Step 5 targets `fmt_cell` (gen-report.py:119) directly and shows the appended code; the only file-specific judgement left to the implementer is which line of the aggregator already reads `verdict.txt` (to add `reason`/`calibration_matched` alongside the existing fields).
