# wal-streamlanes-1m — write-throughput report

## Throughput at saturation (ops/s)

| streams | lanes3x3 |
|---|---|
| 100000 | 374k† |
| 500000 | 285k† |
| 1000000 | 212k† |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | lanes3x3 |
|---|---|
| 100000 | 1053 / 859 |
| 500000 | 3160 / 3026 |
| 1000000 | 5588 / 4968 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Latency (ms, p50 / p99)

| streams | lanes3x3 @≤80% load | lanes3x3 @saturation |
|---|---|---|
| 100000 | 5.3 / 8.7 (374k @8p) | — |
| 500000 | 5.7 / 11.0 (285k @8p) | — |
| 1000000 | 6.0 / 29.7 (212k @8p) | — |

_@≤80% load = the largest ladder rung at ≤80% of peak throughput — the server's service latency with headroom. @saturation = the pinned plateau rung, where a closed-loop fleet measures its own queueing (≈ in-flight ÷ ceiling by Little's law), NOT the server's per-request cost. Compare against the unloaded single-request baseline (~1 ms for wal) before reading anything into large saturation values._

## Saturation walks (pods → ops/s, p50 ms)

- **lanes3x3 100000**: 8:374k@5.3ms  (pinned 8, ladder_exhausted)
- **lanes3x3 500000**: 8:285k@5.7ms  (pinned 8, ladder_exhausted)
- **lanes3x3 1000000**: 8:212k@6.0ms  (pinned 8, ladder_exhausted)

## Findings

_TODO: written by hand on top of the generated data._

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
