# wal-syncfs-local — write-throughput report

## Throughput at saturation (ops/s)

| streams | baseline | syncfs |
|---|---|---|
| 20000 | 87k† | 76k† |
| 50000 | 66k† | 61k† |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | baseline | syncfs |
|---|---|---|
| 20000 | 133 / 119 | 129 / 107 |
| 50000 | 271 / 243 | 255 / 244 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Latency (ms, p50 / p99)

| streams | baseline @≤80% load | baseline @saturation | syncfs @≤80% load | syncfs @saturation |
|---|---|---|---|---|
| 20000 | 5.1 / 18.3 (43k @2p) | — | 3.4 / 11.6 (61k @2p) | — |
| 50000 | 5.9 / 29.0 (35k @2p) | — | 4.1 / 19.7 (48k @2p) | — |

_@≤80% load = the largest ladder rung at ≤80% of peak throughput — the server's service latency with headroom. @saturation = the pinned plateau rung, where a closed-loop fleet measures its own queueing (≈ in-flight ÷ ceiling by Little's law), NOT the server's per-request cost. Compare against the unloaded single-request baseline (~1 ms for wal) before reading anything into large saturation values._

## Saturation walks (pods → ops/s, p50 ms)

- **baseline 20000**: 2:43k@5.1ms → 4:87k@5.5ms  (pinned 4, ladder_exhausted)
- **syncfs 20000**: 2:61k@3.4ms → 4:76k@5.1ms  (pinned 4, ladder_exhausted)
- **baseline 50000**: 2:35k@5.9ms → 4:57k@8.3ms → 6:66k@9.6ms  (pinned 6, ladder_exhausted)
- **syncfs 50000**: 2:48k@4.1ms → 4:55k@6.3ms → 6:61k@8.0ms  (pinned 6, ladder_exhausted)

## Findings

_TODO: written by hand on top of the generated data._

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
