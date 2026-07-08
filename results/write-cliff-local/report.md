# write-cliff-local — write-throughput report

## Throughput at saturation (ops/s)

| streams | wal | memory |
|---|---|---|
| 1000 | 55k† | 113k |
| 10000 | 48k† | 64k |
| 50000 | 28k† | 23k |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | wal | memory |
|---|---|---|
| 1000 | 30 / 22 | 31 / 19 |
| 10000 | 79 / 67 | 70 / 61 |
| 50000 | 253 / 247 | 233 / 227 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Latency (ms, p50 / p99)

| streams | wal @≤80% load | wal @saturation | memory @≤80% load | memory @saturation |
|---|---|---|---|---|
| 1000 | 2.9 / 13.5 (38k @2p) | — | 0.5 / 2.4 (101k @1p) | 0.9 / 4.8 |
| 10000 | 3.0 / 11.2 (37k @2p) | — | 0.6 / 6.2 (64k @1p) | 0.6 / 7.0 |
| 50000 | 5.0 / 26.5 (21k @2p) | — | 3.9 / 67.1 (15k @2p) | 1.6 / 37.0 |

_@≤80% load = the largest ladder rung at ≤80% of peak throughput — the server's service latency with headroom. @saturation = the pinned plateau rung, where a closed-loop fleet measures its own queueing (≈ in-flight ÷ ceiling by Little's law), NOT the server's per-request cost. Compare against the unloaded single-request baseline (~1 ms for wal) before reading anything into large saturation values._

## Saturation walks (pods → ops/s, p50 ms)

- **memory 1000**: 1:101k@0.5ms → 2:113k@0.9ms → 4:108k@2.0ms  (pinned 2, plateau)
- **wal 1000**: 1:20k@2.7ms → 2:38k@2.9ms → 4:55k@4.0ms  (pinned 4, ladder_exhausted)
- **memory 10000**: 1:64k@0.6ms → 2:66k@1.2ms  (pinned 1, plateau)
- **wal 10000**: 1:22k@2.4ms → 2:37k@3.0ms → 4:48k@4.4ms  (pinned 4, ladder_exhausted)
- **memory 50000**: 1:23k@1.4ms → 2:15k@3.9ms  (pinned 1, plateau)
- **wal 50000**: 1:14k@3.6ms → 2:21k@5.0ms → 4:28k@6.7ms  (pinned 4, ladder_exhausted)
- **memory 100000**: 1:18k@1.6ms → 2:13k@5.0ms  (pinned 1, plateau)
- **wal 100000**: 1:7k@6.1ms → 2:10k@8.0ms → 4:10k@17.0ms  (pinned 2, plateau)
- **wal 200000**: 1:6k@8.6ms → 2:7k@12.9ms → 4:6k@25.2ms  (pinned 2, plateau)

## Findings

_TODO: written by hand on top of the generated data._

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
