# wal-stacked-1m — write-throughput report

## Throughput at saturation (ops/s)

| streams | stacked |
|---|---|
| 100000 | 383k† |
| 500000 | 244k† |
| 1000000 | 56k† |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | stacked |
|---|---|
| 100000 | 774 / 668 |
| 500000 | 2925 / 2551 |
| 1000000 | 4939 / 3852 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Latency (ms, p50 / p99)

| streams | stacked @≤80% load | stacked @saturation |
|---|---|---|
| 100000 | 2.5 / 4.5 (383k @4p) | — |
| 500000 | 5.8 / 26.5 (244k @8p) | — |
| 1000000 | 13.9 / 1186.8 (56k @8p) | — |

_@≤80% load = the largest ladder rung at ≤80% of peak throughput — the server's service latency with headroom. @saturation = the pinned plateau rung, where a closed-loop fleet measures its own queueing (≈ in-flight ÷ ceiling by Little's law), NOT the server's per-request cost. Compare against the unloaded single-request baseline (~1 ms for wal) before reading anything into large saturation values._

## Saturation walks (pods → ops/s, p50 ms)

- **stacked 100000**: 4:383k@2.5ms → 8:362k@5.4ms  (pinned 8, ladder_exhausted)
- **stacked 500000**: 8:244k@5.8ms  (pinned 8, ladder_exhausted)
- **stacked 1000000**: 8:56k@13.9ms  (pinned 8, ladder_exhausted)

## Findings

**Stacked ideal config validated**: 382.7k ops/s @100k streams (p4; 362.3k pinned @p8) — matches the ~360k projection from the separately-measured size-trigger (+10%) and CPU-binding (+21-24%) effects. Campaign total: 10.4k -> 383k = 37x, cardinality-flat through 100k.

**A NEW wall near 1M streams**: 500k holds 244k (-36%), 1M collapses to 56k (-85%). This is not the old checkpoint storm (fixed, flat to 100k). Candidate mechanisms for the next investigation: 1M open fds (one per live stream ~= container nofile ceiling), ext4 directory with 1M files, stream-map/tails/meta working set, page-cache pressure from 1M dirty files. Needs a dedicated profiling pass with SRV_STATS/WAL_CKPT telemetry review at 500k/1M.

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
