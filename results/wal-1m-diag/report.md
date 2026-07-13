# wal-1m-diag — write-throughput report

## Throughput at saturation (ops/s)

| streams | stacked |
|---|---|
| 500000 | 252k† |
| 1000000 | 68k† |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | stacked |
|---|---|
| 500000 | 3727 / 3144 |
| 1000000 | 6081 / 5774 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Latency (ms, p50 / p99)

| streams | stacked @≤80% load | stacked @saturation |
|---|---|---|
| 500000 | 5.9 / 13.3 (252k @8p) | — |
| 1000000 | 8.5 / 1102.8 (68k @8p) | — |

_@≤80% load = the largest ladder rung at ≤80% of peak throughput — the server's service latency with headroom. @saturation = the pinned plateau rung, where a closed-loop fleet measures its own queueing (≈ in-flight ÷ ceiling by Little's law), NOT the server's per-request cost. Compare against the unloaded single-request baseline (~1 ms for wal) before reading anything into large saturation values._

## Saturation walks (pods → ops/s, p50 ms)

- **stacked 500000**: 8:252k@5.9ms  (pinned 8, ladder_exhausted)
- **stacked 1000000**: 8:68k@8.5ms  (pinned 8, ladder_exhausted)

## Findings

_TODO: written by hand on top of the generated data._

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
