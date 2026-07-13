# wal-fanout-sweep — write-throughput report

## Throughput at saturation (ops/s)

| streams | s4-f1 | s4-f2 | s4-f4 | s4-f8 |
|---|---|---|---|---|
| 200000 | 71k | 68k | 75k† | 67k† |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | s4-f1 | s4-f2 | s4-f4 | s4-f8 |
|---|---|---|---|---|
| 200000 | 1059 / 1032 | 1032 / 1004 | 1109 / 1049 | 1101 / 1039 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Latency (ms, p50 / p99)

| streams | s4-f1 @≤80% load | s4-f1 @saturation | s4-f2 @≤80% load | s4-f2 @saturation | s4-f4 @≤80% load | s4-f4 @saturation | s4-f8 @≤80% load | s4-f8 @saturation |
|---|---|---|---|---|---|---|---|---|
| 200000 | 8.0 / 32.5 (56k @2p) | 27.9 / 59.3 | 8.2 / 26.5 (59k @2p) | 14.5 / 42.0 | 16.2 / 38.0 (59k @4p) | — | 11.0 / 23.4 (45k @2p) | — |

_@≤80% load = the largest ladder rung at ≤80% of peak throughput — the server's service latency with headroom. @saturation = the pinned plateau rung, where a closed-loop fleet measures its own queueing (≈ in-flight ÷ ceiling by Little's law), NOT the server's per-request cost. Compare against the unloaded single-request baseline (~1 ms for wal) before reading anything into large saturation values._

## Saturation walks (pods → ops/s, p50 ms)

- **s4-f1 200000**: 2:56k@8.0ms → 4:61k@14.5ms → 8:73k@27.3ms → 12:71k@41.4ms → 16:75k@53.4ms  (pinned 8, plateau)
- **s4-f2 200000**: 2:59k@8.2ms → 4:69k@14.4ms → 8:68k@28.1ms → 12:73k@41.3ms  (pinned 4, plateau)
- **s4-f4 200000**: 2:47k@9.6ms → 4:59k@16.2ms → 8:66k@29.0ms → 12:74k@41.5ms → 16:75k@54.5ms  (pinned 16, ladder_exhausted)
- **s4-f8 200000**: 2:45k@11.0ms → 4:55k@17.8ms → 8:59k@33.1ms → 12:65k@45.6ms → 16:67k@59.7ms  (pinned 16, ladder_exhausted)

## Findings

_TODO: written by hand on top of the generated data._

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
