# wal-lazy-checkpoint-local — write-throughput report

## Throughput at saturation (ops/s)

| streams | ref-baseline-3s | ref-syncfs-3s | lazy-syncfs-30s | lazy-syncfs-60s |
|---|---|---|---|---|
| 20000 | 77k† | 88k† | 100k† | 98k† |
| 50000 | 62k | 50k | 72k | 90k† |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | ref-baseline-3s | ref-syncfs-3s | lazy-syncfs-30s | lazy-syncfs-60s |
|---|---|---|---|---|
| 20000 | 128 / 106 | 134 / 123 | 129 / 118 | 128 / 118 |
| 50000 | 262 / 239 | 247 / 238 | 278 / 239 | 281 / 242 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Latency (ms, p50 / p99)

| streams | ref-baseline-3s @≤80% load | ref-baseline-3s @saturation | ref-syncfs-3s @≤80% load | ref-syncfs-3s @saturation | lazy-syncfs-30s @≤80% load | lazy-syncfs-30s @saturation | lazy-syncfs-60s @≤80% load | lazy-syncfs-60s @saturation |
|---|---|---|---|---|---|---|---|---|
| 20000 | 4.5 / 9.5 (55k @2p) | — | 3.5 / 12.3 (60k @2p) | — | 3.2 / 9.4 (69k @2p) | — | 3.1 / 5.2 (80k @2p) | — |
| 50000 | 8.7 / 62.9 (22k @2p) | 6.5 / 30.6 | 3.9 / 19.7 (49k @2p) | 5.9 / 136.3 | 4.2 / 9.4 (58k @2p) | 5.4 / 55.8 | 3.9 / 11.1 (60k @2p) | — |

_@≤80% load = the largest ladder rung at ≤80% of peak throughput — the server's service latency with headroom. @saturation = the pinned plateau rung, where a closed-loop fleet measures its own queueing (≈ in-flight ÷ ceiling by Little's law), NOT the server's per-request cost. Compare against the unloaded single-request baseline (~1 ms for wal) before reading anything into large saturation values._

## Saturation walks (pods → ops/s, p50 ms)

- **lazy-syncfs-30s 20000**: 2:69k@3.2ms → 4:100k@4.8ms  (pinned 4, ladder_exhausted)
- **lazy-syncfs-60s 20000**: 2:80k@3.1ms → 4:98k@4.8ms  (pinned 4, ladder_exhausted)
- **ref-baseline-3s 20000**: 2:55k@4.5ms → 4:77k@6.1ms  (pinned 4, ladder_exhausted)
- **ref-syncfs-3s 20000**: 2:60k@3.5ms → 4:88k@5.0ms  (pinned 4, ladder_exhausted)
- **lazy-syncfs-30s 50000**: 2:58k@4.2ms → 4:81k@5.4ms → 6:72k@7.6ms  (pinned 4, plateau)
- **lazy-syncfs-60s 50000**: 2:60k@3.9ms → 4:80k@5.4ms → 6:90k@7.6ms  (pinned 6, ladder_exhausted)
- **ref-baseline-3s 50000**: 2:22k@8.7ms → 4:64k@7.3ms → 6:64k@9.2ms  (pinned 4, plateau)
- **ref-syncfs-3s 50000**: 2:49k@3.9ms → 4:68k@5.5ms → 6:70k@7.7ms  (pinned 4, plateau)

## Findings

_TODO: written by hand on top of the generated data._

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
