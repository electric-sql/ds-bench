# wal-mem-diag-local — write-throughput report

## Throughput at saturation (ops/s)

| streams | wal-syncfs | memory |
|---|---|---|
| 20000 | 74k† | 170k† |
| 50000 | 23k | 139k |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | wal-syncfs | memory |
|---|---|---|
| 20000 | 133 / 106 | 127 / 117 |
| 50000 | 243 / 226 | 270 / 230 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Latency (ms, p50 / p99)

| streams | wal-syncfs @≤80% load | wal-syncfs @saturation | memory @≤80% load | memory @saturation |
|---|---|---|---|---|
| 20000 | 3.5 / 11.3 (63k @2p) | — | 1.5 / 7.2 (137k @2p) | — |
| 50000 | 4.1 / 39.5 (43k @2p) | 6.3 / 146.9 | 1.5 / 6.4 (146k @2p) | 1.4 / 8.0 |

_@≤80% load = the largest ladder rung at ≤80% of peak throughput — the server's service latency with headroom. @saturation = the pinned plateau rung, where a closed-loop fleet measures its own queueing (≈ in-flight ÷ ceiling by Little's law), NOT the server's per-request cost. Compare against the unloaded single-request baseline (~1 ms for wal) before reading anything into large saturation values._

## Saturation walks (pods → ops/s, p50 ms)

- **memory 20000**: 2:137k@1.5ms → 4:170k@2.2ms  (pinned 4, ladder_exhausted)
- **wal-syncfs 20000**: 2:63k@3.5ms → 4:74k@5.8ms  (pinned 4, ladder_exhausted)
- **memory 50000**: 2:146k@1.5ms → 4:146k@2.6ms  (pinned 2, plateau)
- **wal-syncfs 50000**: 2:43k@4.1ms → 4:37k@8.8ms  (pinned 2, plateau)

## Findings

_TODO: written by hand on top of the generated data._

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
