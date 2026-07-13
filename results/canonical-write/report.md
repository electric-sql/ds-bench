# canonical-write — write-throughput report

## Throughput at saturation (ops/s)

| streams | wal-ideal | memory |
|---|---|---|
| 10000 | 417k† | 680k† |
| 100000 | 382k† | 632k† |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | wal-ideal | memory |
|---|---|---|
| 10000 | 323 / 221 | 298 / 206 |
| 100000 | 777 / 658 | 714 / 630 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Latency (ms, p50 / p99)

| streams | wal-ideal @≤80% load | wal-ideal @saturation | memory @≤80% load | memory @saturation |
|---|---|---|---|---|
| 10000 | 2.4 / 4.2 (417k @4p) | — | 1.4 / 3.6 (656k @4p) | — |
| 100000 | 2.5 / 4.6 (382k @4p) | — | 1.4 / 3.6 (632k @4p) | — |

_@≤80% load = the largest ladder rung at ≤80% of peak throughput — the server's service latency with headroom. @saturation = the pinned plateau rung, where a closed-loop fleet measures its own queueing (≈ in-flight ÷ ceiling by Little's law), NOT the server's per-request cost. Compare against the unloaded single-request baseline (~1 ms for wal) before reading anything into large saturation values._

## Saturation walks (pods → ops/s, p50 ms)

- **memory 10000**: 4:656k@1.4ms → 8:680k@2.8ms  (pinned 8, ladder_exhausted)
- **wal-ideal 10000**: 4:417k@2.4ms → 8:399k@5.0ms  (pinned 8, ladder_exhausted)
- **memory 100000**: 4:632k@1.4ms → 8:622k@2.9ms  (pinned 8, ladder_exhausted)
- **wal-ideal 100000**: 4:382k@2.5ms → 8:365k@5.3ms  (pinned 8, ladder_exhausted)

## Findings

_TODO: written by hand on top of the generated data._

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
