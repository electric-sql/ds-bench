# canonical-write — write-throughput report

## Throughput at saturation (ops/s)

| streams | wal-ideal | memory |
|---|---|---|
| 10000 | 413k† | 669k† |
| 100000 | 386k† | 628k† |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | wal-ideal | memory |
|---|---|---|
| 10000 | 1572 / 221 | 300 / 216 |
| 100000 | 775 / 650 | 725 / 637 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Latency (ms, p50 / p99)

| streams | wal-ideal @≤80% load | wal-ideal @saturation | memory @≤80% load | memory @saturation |
|---|---|---|---|---|
| 10000 | 2.3 / 5.2 (413k @4p) | — | 1.8 / 4.5 (527k @4p) | — |
| 100000 | 2.5 / 4.7 (386k @4p) | — | 1.6 / 5.0 (532k @4p) | — |

_@≤80% load = the largest ladder rung at ≤80% of peak throughput — the server's service latency with headroom. @saturation = the pinned plateau rung, where a closed-loop fleet measures its own queueing (≈ in-flight ÷ ceiling by Little's law), NOT the server's per-request cost. Compare against the unloaded single-request baseline (~1 ms for wal) before reading anything into large saturation values._

## Saturation walks (pods → ops/s, p50 ms)

- **memory 10000**: 4:527k@1.8ms → 8:669k@2.8ms  (pinned 8, ladder_exhausted)
- **wal-ideal 10000**: 4:413k@2.3ms → 8:399k@5.0ms  (pinned 8, ladder_exhausted)
- **memory 100000**: 4:532k@1.6ms → 8:628k@3.0ms  (pinned 8, ladder_exhausted)
- **wal-ideal 100000**: 4:386k@2.5ms → 8:364k@5.3ms  (pinned 8, ladder_exhausted)

## Findings

_TODO: written by hand on top of the generated data._

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
