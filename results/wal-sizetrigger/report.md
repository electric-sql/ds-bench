# wal-sizetrigger — write-throughput report

## Throughput at saturation (ops/s)

| streams | ref-3s | size-1g |
|---|---|---|
| 10000 | 298k† | 314k† |
| 100000 | 275k | 303k |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | ref-3s | size-1g |
|---|---|---|
| 10000 | 236 / 183 | 294 / 186 |
| 100000 | 663 / 591 | 693 / 600 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Latency (ms, p50 / p99)

| streams | ref-3s @≤80% load | ref-3s @saturation | size-1g @≤80% load | size-1g @saturation |
|---|---|---|---|---|
| 10000 | 3.1 / 8.3 (298k @4p) | — | 3.1 / 7.5 (314k @4p) | — |
| 100000 | 1.5 / 6.2 (269k @2p) | 1.5 / 6.4 | 1.5 / 5.8 (296k @2p) | 1.5 / 6.1 |

_@≤80% load = the largest ladder rung at ≤80% of peak throughput — the server's service latency with headroom. @saturation = the pinned plateau rung, where a closed-loop fleet measures its own queueing (≈ in-flight ÷ ceiling by Little's law), NOT the server's per-request cost. Compare against the unloaded single-request baseline (~1 ms for wal) before reading anything into large saturation values._

## Saturation walks (pods → ops/s, p50 ms)

- **ref-3s 10000**: 4:298k@3.1ms → 8:294k@6.5ms  (pinned 8, ladder_exhausted)
- **size-1g 10000**: 4:314k@3.1ms → 8:310k@6.4ms  (pinned 8, ladder_exhausted)
- **ref-3s 100000**: 2:269k@1.5ms → 4:272k@3.1ms → 8:270k@6.5ms  (pinned 2, plateau)
- **size-1g 100000**: 2:296k@1.5ms → 4:292k@3.1ms → 8:290k@6.4ms  (pinned 2, plateau)

## Findings

size-1g (--wal-checkpoint-wal-bytes 1GiB, 60s fallback) reaches the checkpoint-off ceiling: 309.6k @10k / 303.2k @100k vs ckpt-off 305k/306k (wal-splitlane) and ref-3s 293.9k/275.3k. The size trigger reclaims the entire 7-11% checkpoint cost while bounding crash-replay to <=1 GiB retained WAL per shard. Shipped as PR #4704 (stacked on #4697).

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
