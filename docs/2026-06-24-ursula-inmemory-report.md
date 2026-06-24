# Ursula In-Memory Write-Throughput Report — 2026-06-24

Single-node ursula write (append) throughput with the **in-memory Raft WAL**
(`URSULA_WAL=memory`, no disk fsync — ursula's non-durable best case), measured with
the saturation suite and compared against the **disk-WAL** ursula baseline from the
same campaign. Same methodology/cluster as the other runs (4-CPU-pinned server on
`c4d-standard-16-lssd`, 8× `n2d-standard-32` clients, `fleet_cpu=2`, ~1000 streams/pod,
plateau 5%, 3 reps). Ran in parallel with the zero-copy run on an isolated cluster.

Data: `results/write-throughput-ursula-memory/`, `results/ursula-memory-comparison.{md,csv}`.

## Peak throughput

| configuration | peak ops/s | at streams | saturation |
|---|---|---|---|
| **ursula in-memory** | **~154k** | 100 000 | lower bound † (still climbing at 110 pods) |
| ursula disk-WAL | ~10k | 100 000 | plateau ✅ |

## Throughput matrix (ops/s; † = lower bound)

| streams | ursula in-memory | ursula disk-WAL | speedup |
|---|---|---|---|
| 100 | 51k | 4k | ~13× |
| 1 000 | 86k | 5k | ~17× |
| 10 000 | 106k | 6k | ~18× |
| 100 000 | 154k† | 10k | ~15× |

## Saturation walks (pods → ops/s)
- **in-memory n=100**: 4:47k → 8:51k → 16:47k  (plateau, pinned 8)
- **in-memory n=1000**: 4:67k → 8:77k → 16:86k → 24:86k  (plateau, pinned 16)
- **in-memory n=10000**: 16:83k → 24:89k → 32:96k → 48:106k → 64:110k  (plateau, pinned 48)
- **in-memory n=100000**: 80:121k → 100:143k → 110:154k  (ladder_exhausted — lower bound)

## Findings

1. **Removing disk durability is worth ~15× for ursula** — in-memory Raft WAL sustains
   51k–154k ops/s vs 4k–10k on disk WAL, a consistent ~13–18× across all cardinalities.
   ursula's write throughput on disk is dominated by Raft-log fsync; in memory that cost
   disappears.

2. **Throughput scales with cardinality** (51k → 154k as streams go 100 → 100k) — more
   streams give more batching/parallelism for the single-node Raft pipeline.

3. **Even in-memory, ursula is ~4× below durable-streams** — durable-streams `wal` peaks
   ~592–608k *with* disk durability + payload CRC, while ursula's *non-durable* best case
   tops out ~154k. So the gap to durable-streams is architectural (Raft pipeline), not just
   the disk-WAL fsync cost.

4. **No creation chokes or errors** — unlike s2, ursula's stream-creation path handled all
   cardinalities at `setup_concurrency=32`.

## Caveats
- **n=100000 is a lower bound** (`154k†`): the `[80,100,110]` ladder never plateaued
  (121k → 143k → 154k, still climbing at 110 pods). ursula in-memory's true 100k ceiling is
  ≥154k; extend the ladder (more pods) to pin it.
- Single-node, in-memory = **not durable** — this is a best-case throughput reference, not a
  production-comparable durability mode.
- ursula is not server-CPU-instrumented, so saturation is plateau-only (no cpu_pct).
