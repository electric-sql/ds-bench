# Phase 2 — Multi-stream scale-out — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Goal:** The *"Coming next: multi-stream"* experiment from `BENCHMARKS.md` — many
concurrent streams with independent producers/consumers, **swept by stream count**,
**uncapped** (fleet + headroom guard + metrics sidecar) on modern NVMe. DS raw power
across streams: write throughput vs stream count, and multi-stream SSE fan-out delivery
latency. DS-only (cross-system comparison is Phase 4). `fast`/`slow` profiles.

**Architecture:** Almost entirely reuse — `multi_stream.rs` (N-stream writes),
`multi_fanout.rs` (M streams × S subscribers), the metrics sidecar, `gke-sustained.sh`
(stream-count sweep + multi-fanout + sidecar collection), and the `render-sustained.py`
pattern. Phase 2 adds a **scale-out runner** (profile-driven sweep with the Phase-1
headroom guard) and a **scale-out renderer** (curves vs stream count). No new workloads.

## Global Constraints
- Same as Phase 1: **uncapped/server-bound** (headroom guard — scale client pods until the
  server saturates, flag cells where it can't), **server CPU/RSS via the sidecar**, **forked
  files untouched** (reuse `multi_stream.rs`/`multi_fanout.rs` as-is), `fast`/`slow` profiles,
  modern NVMe node, **GKE safety** (`--context …ds-bench -n ds-bench`, never prod), Cloud Build.
- Reuses Phase-1's `gke-rawpower.sh` headroom-guard helper + the sidecar wiring — factor the
  shared pieces so P1 and P2 don't duplicate the scale-until-server-bound loop.

## File Structure
```
scripts/
├── gke-scaleout.sh     # NEW: profile-driven stream-count sweep (multi-stream writes + multi-fanout), headroom-guarded
└── render-scaleout.py  # NEW: write-throughput/p99 vs stream count; fan-out latency vs (M,S); RSS/CPU vs stream count
```

---

### Task 1: `gke-scaleout.sh` — stream-count sweep runner

**Files:** Create `scripts/gke-scaleout.sh`.

- [ ] **Step 1: Write it** — model on `gke-sustained.sh` (CTX/`K()`/RUN_ID, the
  metrics-poller ConfigMap, the fleet→coordinator merge, per-cell `samples.csv` reset +
  collection) and reuse Phase-1's headroom-guard loop (scale client pods until the server is
  CPU-bound; flag `client_capped`). Matrix per PROFILE:
  - `fast`: SERVER_CPU=2; **multi-stream writes** at stream counts {10, 100}; **multi-fanout**
    at {M=10, S=10}; short duration; 1 repeat.
  - `slow`: SERVER_CPU ∈ {8,16}; multi-stream writes at {10, 100, 1k, 10k}; multi-fanout at
    {(M,S) = (10,100), (100,10), (1000,10)}; ~30 s; 3 repeats (median/cv).
  - multi-stream: `BENCH_CMD="multi-stream --streams ${N} --duration-secs … --payload-bytes 256"`,
    `--label-prefix`/`OUT_PREFIX` `ms`; multi-fanout: `BENCH_CMD="multi-fanout --streams ${M}
    --subscribers-per-stream ${S} --writer-rate 50 --duration-secs …"`, prefix `multi-fanout`.
  - Each cell: deploy/scale server at SERVER_CPU; wait-serving; reset sidecar CSV; fleet→merge
    (`hdr-merge --hdr-dir /merge --results-dir /merge --label-prefix <prefix>`); collect
    `merged.json` + `samples.csv` into `results/scaleout/<RUN_ID>/<cell>/`.
- [ ] **Step 2: Verify** — `bash -n`; dry-run the `fast` matrix expansion (echo cells).
  Integration gate (cluster): `scripts/gke-up.sh && scripts/gke-scaleout.sh fast` → a
  multi-stream cell + a multi-fanout cell with non-zero merged + a samples.csv + a headroom verdict.
- [ ] **Step 3: Commit** — `feat(phase2): gke-scaleout.sh — stream-count sweep (writes + multi-fanout), headroom-guarded`.

---

### Task 2: `render-scaleout.py` — scale-out curves

**Files:** Create `scripts/render-scaleout.py`.

- [ ] **Step 1: Write it** — read `results/scaleout/<RUN_ID>/<cell>/{merged.json,samples.csv}`;
  emit `report.md`: (1) **write throughput + p99 vs stream count** (multi-stream cells);
  (2) **multi-stream fan-out delivery p99 + events/s vs (M, S)**; (3) **server RSS + CPU% vs
  stream count** (from `samples.csv` — the scale-out memory/CPU cost). `slow` → median+cv over
  repeats. Mark `client_capped` cells. Reuse `render-sustained.py`'s CSV/JSON helpers + the
  disclosure block (single-node, modern NVMe, sidecar CPU, uncapped/server-bound).
- [ ] **Step 2: Verify** — run on a hand-made sample (a multi-stream cell + a multi-fanout cell)
  → `report.md` with the sections, partial data → `-`, no crash.
- [ ] **Step 3: Commit** — `feat(phase2): render-scaleout.py — scale-out throughput/fan-out/RSS vs stream count`.

---

## Cluster run (integration gate)
Same session as Phase 1: after the workloads + servers are up, `gke-scaleout.sh fast`
(validate) → `gke-scaleout.sh slow` (the matrix) → `render-scaleout.py`.

## Self-Review
- **Coverage:** multi-stream write scale-out ✓ (reuses `multi_stream.rs`), multi-stream
  fan-out ✓ (reuses `multi_fanout.rs`), profiles ✓, headroom-guard ✓ (shared with P1),
  sidecar RSS/CPU ✓. No new workloads — P2 is a runner + renderer.
- **No forked-file edits**; reuses Phase-1 infra (headroom loop, sidecar, merge).
- **DS-only** here; cross-system multi-stream is Phase 4.
