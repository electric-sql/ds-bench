# canonical-write-ursula — write-throughput report

## Throughput at saturation (ops/s)

| streams | ursula-memory | ursula-disk |
|---|---|---|
| 100 | 49k | 4k |
| 1000 | 55k | 7k |
| 10000 | 49k | 8k |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | ursula-memory | ursula-disk |
|---|---|---|
| 100 | 3172 / 2094 | 1311 / 1133 |
| 1000 | 2320 / 1746 | 1744 / 1508 |
| 10000 | 3430 / 2936 | 2610 / 2334 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Latency (ms, p50 / p99)

| streams | ursula-memory @≤80% load | ursula-memory @saturation | ursula-disk @≤80% load | ursula-disk @saturation |
|---|---|---|---|---|
| 100 | 1.1 / 34.9 (48k @4p) | 1.1 / 34.3 | 6.6 / 84.7 (4k @4p) | 6.6 / 84.6 |
| 1000 | 11.0 / 62.9 (54k @4p) | 11.0 / 63.2 | 111.4 / 298.5 (7k @4p) | 112.1 / 297.5 |
| 10000 | 203.0 / 296.4 (49k @8p) | 203.4 / 304.6 | 1402.9 / 1905.7 (8k @8p) | 1404.9 / 1901.6 |

_@≤80% load = the largest ladder rung at ≤80% of peak throughput — the server's service latency with headroom. @saturation = the pinned plateau rung, where a closed-loop fleet measures its own queueing (≈ in-flight ÷ ceiling by Little's law), NOT the server's per-request cost. Compare against the unloaded single-request baseline (~1 ms for wal) before reading anything into large saturation values._

## Saturation walks (pods → ops/s, p50 ms)

- **ursula-disk 100**: 4:4k@6.6ms → 8:5k@6.5ms  (pinned 4, plateau)
- **ursula-memory 100**: 4:48k@1.1ms → 8:52k@1.2ms  (pinned 4, plateau)
- **ursula-disk 1000**: 4:7k@111.4ms → 8:7k@111.3ms  (pinned 4, plateau)
- **ursula-memory 1000**: 4:54k@11.0ms → 8:54k@11.1ms  (pinned 4, plateau)
- **ursula-disk 10000**: 8:8k@1402.9ms → 16:8k@1398.8ms  (pinned 8, plateau)
- **ursula-memory 10000**: 8:49k@203.0ms → 16:48k@203.5ms  (pinned 8, plateau)

## Findings

_TODO: written by hand on top of the generated data._

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
