# wal vs memory write saturation — 4 & 8 pinned vCPUs (2026-07-08 campaign)

Covers **both** suites of the campaign: `write-wal-vs-mem-cpu4` (this dir) and
`write-wal-vs-mem-cpu8` (sibling). One combined write-up because the story is the
comparison.

## Setup

- **Server:** `durable-streams:dev` built from `electric` branch
  **`vb/ds-rust-memory-meta-sweep`** (= PR #4675 wal coordination fixes + #4691
  memory-mode meta-sidecar sweep). Node `c4d-standard-16-lssd` (physically-attached
  Titanium NVMe local SSD), CPU-pinned via cgroup to **4** resp. **8** vCPUs
  (`cluster.server_cpus`). wal: `--wal-shards N --worker-threads N` (N = pin);
  memory: `--durability memory --worker-threads N`.
- **Client:** rewritten pool model (this repo, post-`f25d721` fix): pods own
  **disjoint slices of the global key domain**, plain appends (no producer
  sessions), slices pre-created **before** the fleet start barrier, 256
  connections/pod @ `fleet_cpu=2`, batch 1, 256 B payloads, 25 s measure.
- **Validity:** every cell `windows_aligned=true` (span = the 25 s window — the
  barrier aligns starts to milliseconds); zero client errors; client accuracy
  verified locally against server-side stream offsets (delta = 0 records, both
  configs) before the campaign.

## Headline: memory is 4.5–7× wal

| server vCPU | streams | wal (pinned) | memory (pinned) | memory/wal | wal p50/p99 (ms) | memory p50/p99 (ms) |
|---|---|---|---|---|---|---|
| 4 | 100k | **59.2k** @16 pods | **297.2k** @8 pods | **5.0×** | 64 / 104 | 2.2 / 37 |
| 4 | 500k | **47.9k** @24 pods | **216.4k** @8 pods | **4.5×** | 129 / 488 | 2.2 / 64 |
| 8 | 100k | **68.8k** @16 pods | **483.6k** @32 pods | **7.0×** | 57 / 108 | 2.8 / 75 |
| 8 | 500k | **46.6k** @16 pods | **322.3k** @16 pods | **6.9×** | 84 / 212 | 2.8 / 58 |

- **memory scales with cores** (297k → 484k @100k, +63% for 2× vCPU) and pays a
  ~27–33% cardinality tax from 100k → 500k streams.
- **wal does NOT scale with cores** (59k → 69k, +16% for 2× vCPU) and its server CPU
  sat at only ~25–30% of the pin while p50 was tens of ms — the wal ceiling here is
  the **commit path (fsync cadence × group-commit batch) on the single NVMe
  partition**, not compute and not the client. Known lever: more WAL shards than
  cores (`run-durable-tune` measured s16t4 ≈ 380k @200k streams, ~6× the s4t4
  number here) — shards set the number of parallel fsync lanes.

## Why earlier numbers disagreed (the accuracy story)

- The pre-barrier "4-vCPU wal ≈ 0.7–2M+" readings were **window-misalignment
  inflation** (summing per-pod rates measured at different wall times —
  `results-backup-2026-07-06/run-durable-prebarrier` peaks at 3.05M while disk
  telemetry idled). The fleet start barrier + `windows_aligned` gate fixed that.
- The post-barrier "wal 500k ≈ 32k" readings from the random-domain client
  (`run-durable-pool-barrier`) were **deflated**: that client had no setup phase, so
  high-cardinality cells spent the measure window on 404→create→retry storms. The
  rewritten client pre-creates each pod's disjoint slice before the barrier; the
  `lazy_creates` field in every pod JSON proves creation stayed out of the window.
- The legitimate ~1M+ wal numbers in the archive (e.g. 1.11M @ 1M streams) are
  **16 vCPU / 16 shard** results — not comparable to a 4-shard 4-vCPU pin.

## Provenance

- ds-bench: branch `fix/fleet-measure-window-alignment`, client rewrite of
  `ds-bench/src/multi_stream.rs` (disjoint per-pod slices + setup-before-barrier +
  `ok_total_all_phases`/`lazy_creates`), harness fix in `scripts/lib-bench.sh`
  (full run-prefix reset — kills cross-label stale-result reuse).
- server image: Cloud Build 8dfd6c08 (2026-07-08) from
  `packages/durable-streams-rust` @ `40b7c4677` (`vb/ds-rust-memory-meta-sweep`).
- client image: Cloud Build a846e93c (2026-07-08).
- Accuracy validation: `suites/write-accuracy-local.json` +
  `scripts/verify-accuracy-cell.sh` — server records == client records (delta 0)
  for both wal and memory configs on kind.
