# wal vs memory write saturation — 4 & 8 pinned vCPUs (2026-07-08, corrected)

Covers **both** suites of the campaign: `write-wal-vs-mem-cpu4` (this dir) and
`write-wal-vs-mem-cpu8` (sibling). This is the **corrected** run: the first pass
(same day) quoted latency from the saturation plateau rung, which for a
closed-loop fleet is queueing (in-flight ÷ ceiling — Little's law), not service
time. Ladders now start at 1 pod, every rung records its own p50/p99 in the
walk, and latency is quoted from the ≤80%-of-peak **knee** rung.

## Setup

- **Server:** `durable-streams:dev` from `electric` branch
  **`vb/ds-rust-memory-meta-sweep`** (#4675 wal coordination fixes + #4691
  memory meta-sidecar sweep). `c4d-standard-16-lssd` (physically-attached
  Titanium NVMe), CPU-pinned via cgroup to **4** resp. **8** vCPUs. wal:
  `--wal-shards N --worker-threads N` (N = pin); memory:
  `--durability memory --worker-threads N`.
- **Client:** pool model — disjoint per-pod slices of the global key domain,
  plain appends, slices pre-created before the fleet barrier, 256
  connections/pod @ `fleet_cpu=2`, batch 1, 256 B payloads, 25 s measure,
  ladder 1 → 2 → 4 → … pods. Every cell `windows_aligned=true`, zero client
  errors, `lazy_creates=0`.

## Headline (plateau throughput; latency at the ≤80% knee rung)

| server vCPU | streams | wal thr | wal p50/p99 (knee) | memory thr | memory p50/p99 (knee) | memory/wal |
|---|---|---|---|---|---|---|
| 4 | 100k | **47k** | 4.5 / 15.5 ms | **315k** | 1.2 / 2.7 ms | **6.7×** |
| 4 | 500k | **31k** | 6.7 / 30.7 ms | **226k** | 1.1 / 2.4 ms | **7.3×** |
| 8 | 100k | **43k** | 5.0 / 19.7 ms | **526k** | 1.2 / 2.5 ms | **12.2×** |
| 8 | 500k | **29k** | 6.9 / 32.9 ms | **323k** | 1.3 / 2.6 ms | **11.1×** |

- **memory scales with cores** (315k → 526k @100k for 2× vCPU) at ~1–2 ms p50
  throughout; it pays a ~28–39% cardinality tax from 100k → 500k streams.
- **wal does not scale with cores** (47k@4 ≈ 43k@8) and its knee sits at
  ~4.5–7 ms p50: the ceiling is the **commit path (fsync lanes = wal shards) on
  the single NVMe partition**, reached at ~25–30% server CPU. Known lever:
  shards > cores (`run-durable-tune`: s16t4 ≈ 380k @200k streams).

## Methodology: latency is measured BELOW the knee (manually verified)

The first pass reported wal@100k as "59k, p50 64 ms". Manual verification
(2026-07-08, `scripts/manual-wal-latency.sh` — plain curl + a single-pod
concurrency ramp on the same server shape) showed:

| in-flight | ops/s | p50 |
|---|---|---|
| 1 (curl, not ds-bench) | — | **1.02 ms** |
| 64 | 19.8k | 2.2 ms |
| 256 | 45.5k | 5.1 ms |
| 1024 | 56.9k | 17.3 ms |
| 4096 | 61.5k | **65.7 ms** |

One pod at 4096 in-flight reproduces the old 16-pod fleet cell (59k @ 64 ms)
almost exactly — the load generator was **accurate**, but every ladder rung sat
past the knee, so the recorded latency was queueing, not the server. Two
consequences, both fixed:

1. **Latency** is now quoted from the largest rung at ≤80% of peak throughput
   (the `## Latency` table in report.md; knee_* columns in aggregate.csv). The
   plateau rung's latency is still shown, labelled as saturation queueing.
2. **"Saturation throughput" reads slightly lower than before** (wal 47k vs
   59k): the 8%-gain plateau rule with 1→2→4 rung steps now stops near the
   knee instead of deep in the queue-heavy regime, where pushing 4096+ in-flight
   buys ~25% more throughput at 10× the latency. The knee value is the honest
   capacity number; the deep-saturation asymptote (~61k for wal@100k/4 vCPU) is
   documented here for continuity.

## Provenance

- ds-bench branch `fix/fleet-measure-window-alignment`: pool-client rewrite
  (disjoint slices, setup-before-barrier), per-rung latency in walks
  (`saturation.py` / `lib-bench.sh` / `lib-saturate.sh`), knee reporting
  (`report.py:knee_of`), `verify-offsets` server-truth tooling (delta 0 on kind
  for both configs), fleet-apply retry + idempotent cluster adoption
  (`cluster-up.sh`), scoped teardown watchdogs.
- Server image: Cloud Build 8dfd6c08 from `packages/durable-streams-rust` @
  `40b7c4677`; client image: Cloud Build a846e93c.
- Operational note: the first two rerun attempts died to (a) an unscoped
  parallel watchdog sweeping the campaign's clusters mid-deploy — watchdogs are
  now scoped via `CLUSTER_FILTER` — and (b) an interrupted cluster create
  leaving no client pool — `cluster-up.sh` now heals that on adoption.
