# Write-Throughput Benchmark — Final Results

Maintained final dataset. Per-config data points live in
`results/final/write-throughput/<config>/cells.json`; this report summarizes them.

**Methodology:** single-node, best-case append throughput. 4-CPU-pinned server on
`c4d-standard-16-lssd`, `n2d-standard-32` client fleet, `fleet_cpu=2`, ~1000 streams/pod,
saturation walk pins the pod count where throughput stops gaining ≥5%, median of 3 reps.

**Configurations**
- **wal** — durable-streams, WAL durability, `--wal-shards 4`, resident tail-cache **off**,
  zero-copy **off** (the current production-recommended config; verified cache-off).
- **ursula in-memory** — ursula single-node Raft, `URSULA_WAL=memory` (non-durable best case).
- **ursula disk** — ursula single-node Raft, disk WAL (durable).
- **s2** — S2-lite, object-store backed.
- **zero-copy** — _reserved; a replacement build will be benchmarked here later._

## Peak append throughput (ops/s)

| configuration | peak | at streams | note |
|---|---|---|---|
| **wal** | **~754k** | 100 000 | peak @~190 pods; degrades if over-driven (≈376k @280 pods) |
| **ursula in-memory** | ~154k † | 100 000 | ~server-bound ≈150k (lower bound; more clients don't help) |
| **ursula disk** | ~10k | 100 000 | durable Raft fsync bound |
| **s2** | ~2k | 100 | creation-choked at ≥1 000 streams |
| _zero-copy_ | _TBD_ | — | _reserved_ |

## Throughput matrix (ops/s; † = lower bound)

| streams | wal | ursula in-mem | ursula disk | s2 |
|---|---|---|---|---|
| 100 | 504k † | 51k | 4k | 2k |
| 1 000 | 444k | 86k | 5k | choke |
| 10 000 | 629k † | 106k | 6k | choke |
| 100 000 | **754k** | 154k † | 10k | choke |

### Write latency at saturation — p50 / p99 (ms)
At the pinned (saturating) pod count — latencies *under max load* (so p99 is the
queueing tail at the throughput ceiling).

| streams | wal | ursula in-mem | ursula disk | s2 |
|---|---|---|---|---|
| 100 | 0.24 / 0.39 | 0.59 / 35.3 | 32.5 / 63.4 | 51.0 / 52.3 |
| 1 000 | 1.31 / 8.8 | 4.40 / 102 | 196.6 / 500.7 | choke |
| 10 000 | 1.42 / 90.4 | 14.9 / 474 | 1500 / 4698 | choke |
| 100 000 | 2.40 / 801.8 | 67.3 / 3330 | 6119 / 20005 | choke |

**wal median stays sub-ms–to–~2.4ms** even at saturation (p99 tail grows with the backlog);
ursula in-memory rises into tens of ms; **ursula disk hits hundreds of ms→seconds** (Raft-log
fsync under load — p99 ~20s at 100k); s2 ~51ms then chokes.

## SSE fan-out — delivery latency, p50 / p99 (ms)

1 stream, 1 writer @ 50 ev/s, swept total subscribers, single client pod (one wall
clock). Writer-paced. Full spread (p90/p999/max) in `results/final/sse/`.

| subscribers | wal (cache off) | wal (cache on) | ursula in-mem | ursula disk | s2 |
|---|---|---|---|---|---|
| 1 | 0.38 / 0.56 | 0.32 / 0.50 | 0.39 / 0.57 | 0.41 / 0.63 | — |
| 10 | 0.48 / 0.67 | 0.45 / 0.65 | 0.49 / 0.66 | 0.50 / 0.70 | 51.3 / 52.0 |
| 100 | 0.84 / 1.17 | 0.79 / 1.14 | 0.81 / 1.11 | 0.87 / 1.20 | 50.9 / 52.0 |
| 1000 | 3.60 / 5.06 | **2.85 / 4.30** | 2.67 / 3.92 | 2.95 / 4.50 | 52.2 / 54.0 |

- **wal and ursula are competitive** (sub-ms to ~3.6ms median across the fan-out).
- **Residency cache helps SSE** ~15–20% at high fan-out (wal p50 2.85 vs 3.60 ms @1000 subs) —
  unlike writes where it was neutral, the cache is a read-path win for delivery.
- **ursula disk ≈ in-memory at the median** (2.95 vs 2.67 ms @1000 subs); the writer-side
  fsync gap shows up in the **tail** (see the p99/max spread in `results/final/sse/`).
- **s2 ~51ms median — ~10–50× slower** (object-store delivery path).

## Per-config notes
- **wal** is the clear leader: ~**750k appends/s on 4 CPU**, ~5× ursula-in-memory, ~75× ursula-disk,
  ~375× s2. Peaks around 190 client pods; over-driving the fleet degrades it (server overload),
  so ~750k is the usable ceiling, not a flat shelf. (`n=1000` reads low at 444k — a run-to-run
  variance artifact; cardinalities around it are 504k–629k.)
- **ursula in-memory** is ~15× faster than disk-WAL ursula but still ~5× below wal — the gap is
  architectural (single-node Raft pipeline), not just fsync. 100k is a lower bound (~150k, server-bound).
- **ursula disk** ~4k–10k, dominated by Raft-log fsync.
- **s2** measurable only at 100 streams (~2k); object-store stream-creation chokes at ≥1 000 streams.

## Caveats
- Single-node, best-case; not multi-node/replicated. ursula/s2 are not server-CPU-instrumented.
- Cross-run/cluster variance ~≤20%; trust same-cluster comparisons.
- Source of each data point + the superseded experimental runs are in `results/trash/`.
