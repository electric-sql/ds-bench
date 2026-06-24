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

## SSE fan-out — delivery latency, p99 (ms)

1 stream, 1 writer @ 50 ev/s, swept total subscribers, single client pod (one wall
clock). Writer-paced, so the metric is delivery **p99 latency** (not throughput).
Data: `results/final/sse/`.

| subscribers | wal (cache off) | wal (cache on) | ursula in-mem | ursula disk | s2 |
|---|---|---|---|---|---|
| 1 | 0.56 | 0.50 | 0.57 | 0.63 | — |
| 10 | 0.67 | 0.65 | 0.66 | 0.70 | 52.0 |
| 100 | 1.17 | 1.14 | 1.11 | 1.20 | 52.0 |
| 1000 | 5.06 | **4.30** | 3.92 | 4.50 | 54.0 |

- **wal and ursula are competitive** (sub-ms to ~5ms across the fan-out).
- **Residency cache helps SSE** ~10–15% at high fan-out (wal 4.30 vs 5.06 ms @1000 subs) —
  unlike writes where it was neutral, the cache is a read-path win for delivery.
- **ursula disk's fsync adds tail latency** vs in-memory at 1000 subs (4.50 vs 3.92).
- **s2 ~52ms — ~10–50× slower** (object-store delivery path).

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
