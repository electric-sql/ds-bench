# wal-batched-mw-local — write-throughput report

## Throughput at saturation (ops/s)

| streams | baseline | batched-mw |
|---|---|---|
| 50000 | 43k | 49k |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | baseline | batched-mw |
|---|---|---|
| 50000 | 249 / 237 | 250 / 239 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Latency (ms, p50 / p99)

| streams | baseline @≤80% load | baseline @saturation | batched-mw @≤80% load | batched-mw @saturation |
|---|---|---|---|---|
| 50000 | 5.5 / 126.7 (27k @2p) | 7.4 / 177.5 | 4.6 / 76.4 (39k @2p) | 6.8 / 145.3 |

_@≤80% load = the largest ladder rung at ≤80% of peak throughput — the server's service latency with headroom. @saturation = the pinned plateau rung, where a closed-loop fleet measures its own queueing (≈ in-flight ÷ ceiling by Little's law), NOT the server's per-request cost. Compare against the unloaded single-request baseline (~1 ms for wal) before reading anything into large saturation values._

## Saturation walks (pods → ops/s, p50 ms)

- **baseline 50000**: 2:27k@5.5ms → 4:50k@6.7ms → 6:48k@9.7ms  (pinned 4, plateau)
- **batched-mw 50000**: 2:39k@4.6ms → 4:49k@7.0ms → 6:54k@9.3ms  (pinned 4, plateau)

## Findings

_TODO: written by hand on top of the generated data._

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
