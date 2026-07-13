# wal-decomp-lane0 — write-throughput report

## Throughput at saturation (ops/s)

| streams | memory | nofsync | ckpt-off | ref-3s |
|---|---|---|---|---|
| 10000 | 543k† | 260k† | 85k† | 55k† |
| 100000 | 511k† | 253k† | 66k† | 47k† |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | memory | nofsync | ckpt-off | ref-3s |
|---|---|---|---|---|
| 10000 | 274 / 190 | 222 / 177 | 176 / 146 | 162 / 144 |
| 100000 | 659 / 597 | 644 / 596 | 586 / 506 | 523 / 509 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Latency (ms, p50 / p99)

| streams | memory @≤80% load | memory @saturation | nofsync @≤80% load | nofsync @saturation | ckpt-off @≤80% load | ckpt-off @saturation | ref-3s @≤80% load | ref-3s @saturation |
|---|---|---|---|---|---|---|---|---|
| 10000 | 1.8 / 4.1 (543k @4p) | — | 3.1 / 9.1 (260k @4p) | — | 11.4 / 15.3 (76k @4p) | — | 13.9 / 58.2 (53k @4p) | — |
| 100000 | 1.2 / 2.4 (408k @2p) | — | 1.5 / 7.4 (253k @2p) | — | 6.8 / 8.8 (66k @2p) | — | 8.9 / 36.6 (47k @2p) | — |

_@≤80% load = the largest ladder rung at ≤80% of peak throughput — the server's service latency with headroom. @saturation = the pinned plateau rung, where a closed-loop fleet measures its own queueing (≈ in-flight ÷ ceiling by Little's law), NOT the server's per-request cost. Compare against the unloaded single-request baseline (~1 ms for wal) before reading anything into large saturation values._

## Saturation walks (pods → ops/s, p50 ms)

- **ckpt-off 10000**: 4:76k@11.4ms → 8:85k@22.5ms  (pinned 8, ladder_exhausted)
- **memory 10000**: 4:543k@1.8ms → 8:542k@3.0ms  (pinned 8, ladder_exhausted)
- **nofsync 10000**: 4:260k@3.1ms → 8:260k@6.4ms  (pinned 8, ladder_exhausted)
- **ref-3s 10000**: 4:53k@13.9ms → 8:55k@36.8ms  (pinned 8, ladder_exhausted)
- **ckpt-off 100000**: 2:66k@6.8ms → 4:65k@13.8ms  (pinned 4, ladder_exhausted)
- **memory 100000**: 2:408k@1.2ms → 4:511k@1.8ms  (pinned 4, ladder_exhausted)
- **nofsync 100000**: 2:253k@1.5ms → 4:253k@3.2ms  (pinned 4, ladder_exhausted)
- **ref-3s 100000**: 2:47k@8.9ms → 4:46k@21.5ms  (pinned 4, ladder_exhausted)

## Findings

_TODO: written by hand on top of the generated data._

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
