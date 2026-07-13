# wal-fsync-diag-local — write-throughput report

## Throughput at saturation (ops/s)

| streams | wal-normal | wal-nofsync | memory |
|---|---|---|---|
| 20000 | 75k† | 98k | 165k |
| 50000 | 69k† | 103k | 133k |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | wal-normal | wal-nofsync | memory |
|---|---|---|---|
| 20000 | 128 / 110 | 132 / 118 | 121 / 112 |
| 50000 | 259 / 244 | 290 / 244 | 266 / 231 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Latency (ms, p50 / p99)

| streams | wal-normal @≤80% load | wal-normal @saturation | wal-nofsync @≤80% load | wal-nofsync @saturation | memory @≤80% load | memory @saturation |
|---|---|---|---|---|---|---|
| 20000 | 3.7 / 14.0 (56k @2p) | — | 1.9 / 7.4 (118k @2p) | 2.1 / 10.0 | 1.3 / 5.7 (163k @2p) | 1.3 / 5.3 |
| 50000 | 6.2 / 138.9 (52k @4p) | — | 2.2 / 10.2 (91k @2p) | 4.3 / 15.5 | 5.5 / 53.5 (58k @4p) | 1.5 / 7.7 |

_@≤80% load = the largest ladder rung at ≤80% of peak throughput — the server's service latency with headroom. @saturation = the pinned plateau rung, where a closed-loop fleet measures its own queueing (≈ in-flight ÷ ceiling by Little's law), NOT the server's per-request cost. Compare against the unloaded single-request baseline (~1 ms for wal) before reading anything into large saturation values._

## Saturation walks (pods → ops/s, p50 ms)

- **memory 20000**: 2:163k@1.3ms → 4:177k@2.2ms  (pinned 2, plateau)
- **wal-nofsync 20000**: 2:118k@1.9ms → 4:120k@3.8ms  (pinned 2, plateau)
- **wal-normal 20000**: 2:56k@3.7ms → 4:75k@5.8ms  (pinned 4, ladder_exhausted)
- **memory 50000**: 2:146k@1.4ms → 4:58k@5.5ms  (pinned 2, plateau)
- **wal-nofsync 50000**: 2:91k@2.2ms → 4:101k@4.3ms → 6:99k@6.6ms  (pinned 4, plateau)
- **wal-normal 50000**: 2:28k@5.2ms → 4:52k@6.2ms → 6:69k@7.9ms  (pinned 6, ladder_exhausted)

## Findings

_TODO: written by hand on top of the generated data._

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
