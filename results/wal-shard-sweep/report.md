# wal-shard-sweep — write-throughput report

## Throughput at saturation (ops/s)

| streams | wal-s1 | wal-s4 | wal-s8 | wal-s16 | wal-s24 |
|---|---|---|---|---|---|
| 200000 | 66k | 67k | 67k | 71k | 64k |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | wal-s1 | wal-s4 | wal-s8 | wal-s16 | wal-s24 |
|---|---|---|---|---|---|
| 200000 | 1088 / 1055 | 1092 / 1076 | 1041 / 1020 | 1073 / 1048 | 1100 / 1063 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Latency (ms, p50 / p99)

| streams | wal-s1 @≤80% load | wal-s1 @saturation | wal-s4 @≤80% load | wal-s4 @saturation | wal-s8 @≤80% load | wal-s8 @saturation | wal-s16 @≤80% load | wal-s16 @saturation | wal-s24 @≤80% load | wal-s24 @saturation |
|---|---|---|---|---|---|---|---|---|---|---|
| 200000 | 4.2 / 21.7 (54k @1p) | 27.8 / 96.2 | 14.7 / 50.5 (60k @4p) | 27.6 / 84.7 | 8.4 / 31.9 (55k @2p) | 14.6 / 40.2 | 10.2 / 21.2 (49k @2p) | 28.6 / 59.1 | 18.8 / 46.0 (52k @4p) | 30.3 / 66.2 |

_@≤80% load = the largest ladder rung at ≤80% of peak throughput — the server's service latency with headroom. @saturation = the pinned plateau rung, where a closed-loop fleet measures its own queueing (≈ in-flight ÷ ceiling by Little's law), NOT the server's per-request cost. Compare against the unloaded single-request baseline (~1 ms for wal) before reading anything into large saturation values._

## Saturation walks (pods → ops/s, p50 ms)

- **wal-s1 200000**: 1:54k@4.2ms → 2:59k@7.4ms → 4:62k@14.1ms → 8:72k@27.6ms → 12:68k@41.5ms → 16:67k@55.0ms  (pinned 8, plateau)
- **wal-s16 200000**: 1:34k@7.1ms → 2:49k@10.2ms → 4:60k@16.4ms → 8:68k@28.8ms → 12:72k@42.1ms → 16:73k@55.1ms  (pinned 8, plateau)
- **wal-s24 200000**: 1:34k@7.1ms → 2:43k@11.4ms → 4:52k@18.8ms → 8:67k@30.0ms → 12:68k@43.6ms → 16:71k@56.4ms  (pinned 8, plateau)
- **wal-s4 200000**: 1:49k@4.7ms → 2:56k@7.9ms → 4:60k@14.7ms → 8:69k@27.9ms → 12:71k@41.3ms → 16:75k@53.9ms  (pinned 8, plateau)
- **wal-s8 200000**: 1:42k@5.7ms → 2:55k@8.4ms → 4:68k@14.6ms → 8:72k@27.8ms → 12:73k@41.6ms  (pinned 4, plateau)

## Findings

_TODO: written by hand on top of the generated data._

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
