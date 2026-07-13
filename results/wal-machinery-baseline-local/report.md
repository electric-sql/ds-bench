# wal-machinery-baseline-local — write-throughput report

## Throughput at saturation (ops/s)

| streams | wal-baseline |
|---|---|
| 50000 | 51k† |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | wal-baseline |
|---|---|
| 50000 | 252 / 242 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Latency (ms, p50 / p99)

| streams | wal-baseline @≤80% load | wal-baseline @saturation |
|---|---|---|
| 50000 | 4.5 / 129.0 (33k @2p) | — |

_@≤80% load = the largest ladder rung at ≤80% of peak throughput — the server's service latency with headroom. @saturation = the pinned plateau rung, where a closed-loop fleet measures its own queueing (≈ in-flight ÷ ceiling by Little's law), NOT the server's per-request cost. Compare against the unloaded single-request baseline (~1 ms for wal) before reading anything into large saturation values._

## Saturation walks (pods → ops/s, p50 ms)

- **wal-baseline 50000**: 2:33k@4.5ms → 4:46k@6.7ms → 6:51k@9.4ms  (pinned 6, ladder_exhausted)

## Findings

_TODO: written by hand on top of the generated data._

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
