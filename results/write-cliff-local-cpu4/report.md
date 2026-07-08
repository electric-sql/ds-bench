# write-cliff-local-cpu4 — write-throughput report

## Throughput at saturation (ops/s)

| streams | wal-cpu4 |
|---|---|
| 10000 | 44k† |
| 50000 | 32k† |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | wal-cpu4 |
|---|---|
| 10000 | 78 / 70 |
| 50000 | 255 / 247 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Latency (ms, p50 / p99)

| streams | wal-cpu4 @≤80% load | wal-cpu4 @saturation |
|---|---|---|
| 10000 | 3.8 / 13.0 (31k @2p) | — |
| 50000 | 5.6 / 29.9 (18k @2p) | — |

_@≤80% load = the largest ladder rung at ≤80% of peak throughput — the server's service latency with headroom. @saturation = the pinned plateau rung, where a closed-loop fleet measures its own queueing (≈ in-flight ÷ ceiling by Little's law), NOT the server's per-request cost. Compare against the unloaded single-request baseline (~1 ms for wal) before reading anything into large saturation values._

## Saturation walks (pods → ops/s, p50 ms)

- **wal-cpu4 10000**: 1:13k@4.2ms → 2:31k@3.8ms → 4:44k@5.0ms  (pinned 4, ladder_exhausted)
- **wal-cpu4 50000**: 1:12k@4.0ms → 2:18k@5.6ms → 4:32k@6.1ms  (pinned 4, ladder_exhausted)

## Findings

_TODO: written by hand on top of the generated data._

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
