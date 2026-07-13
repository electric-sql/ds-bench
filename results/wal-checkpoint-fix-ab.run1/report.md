# wal-checkpoint-fix-ab — write-throughput report

## Throughput at saturation (ops/s)

| streams | baseline | stagger | syncfs | both |
|---|---|---|---|---|
| 10000 | 111k† | 108k | 285k | ERROR (creation_choke) |
| 100000 | 11k | 12k | 15k | 11k |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | baseline | stagger | syncfs | both |
|---|---|---|---|---|
| 10000 | — | — | — | — |
| 100000 | — | — | 485 / 434 | — |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Latency (ms, p50 / p99)

| streams | baseline @≤80% load | baseline @saturation | stagger @≤80% load | stagger @saturation | syncfs @≤80% load | syncfs @saturation | both @≤80% load | both @saturation |
|---|---|---|---|---|---|---|---|---|
| 10000 | 2.7 / 24.7 (106k @2p) | — | 3.3 / 22.0 (108k @2p) | 3.3 / 21.5 | 1.5 / 7.1 (300k @2p) | 1.5 / 8.1 | 0.0 / 0.0 (0k @8p) | — |
| 100000 | 282.4 / 654.3 (7k @8p) | 36.3 / 215.8 | 104.5 / 722.9 (9k @4p) | 37.3 / 363.5 | 4.7 / 1599.5 (9k @4p) | 1.6 / 1419.3 | 187.0 / 1298.4 (9k @8p) | 1.8 / 1217.5 |

_@≤80% load = the largest ladder rung at ≤80% of peak throughput — the server's service latency with headroom. @saturation = the pinned plateau rung, where a closed-loop fleet measures its own queueing (≈ in-flight ÷ ceiling by Little's law), NOT the server's per-request cost. Compare against the unloaded single-request baseline (~1 ms for wal) before reading anything into large saturation values._

## Saturation walks (pods → ops/s, p50 ms)

- **baseline 10000**: 2:106k@2.7ms → 4:96k@9.6ms → 8:111k@17.3ms → 12:95k@31.0ms  (pinned 12, ladder_exhausted)
- **both 10000**: 2:289k@1.5ms → 4:292k@3.1ms → 8:0k@0.0ms  (pinned None, creation_choke)
- **stagger 10000**: 2:108k@3.3ms → 4:100k@8.1ms → 8:99k@19.7ms  (pinned 2, plateau)
- **syncfs 10000**: 2:300k@1.5ms → 4:295k@3.1ms → 8:280k@6.5ms  (pinned 2, plateau)
- **baseline 100000**: 2:10k@38.3ms → 4:9k@99.3ms → 8:7k@282.4ms  (pinned 2, plateau)
- **both 100000**: 2:14k@1.6ms → 4:12k@3.8ms → 8:9k@187.0ms  (pinned 2, plateau)
- **stagger 100000**: 2:12k@30.7ms → 4:9k@104.5ms → 8:7k@267.8ms  (pinned 2, plateau)
- **syncfs 100000**: 2:19k@1.6ms → 4:9k@4.7ms → 8:7k@242.0ms  (pinned 2, plateau)

## Findings

_TODO: written by hand on top of the generated data._

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
