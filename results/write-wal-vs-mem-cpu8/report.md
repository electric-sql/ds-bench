# write-wal-vs-mem-cpu8 — write-throughput report

## Throughput at saturation (ops/s)

| streams | wal | memory |
|---|---|---|
| 100000 | 43k | 526k |
| 500000 | 29k | 323k |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | wal | memory |
|---|---|---|
| 100000 | 575 / 490 | 698 / 608 |
| 500000 | 2425 / 2291 | 2629 / 1980 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Latency (ms, p50 / p99)

| streams | wal @≤80% load | wal @saturation | memory @≤80% load | memory @saturation |
|---|---|---|---|---|
| 100000 | 5.0 / 19.7 (43k @1p) | 4.9 / 20.3 | 1.2 / 2.5 (388k @2p) | 1.6 / 8.1 |
| 500000 | 6.9 / 32.9 (29k @1p) | 7.3 / 29.6 | 1.3 / 2.6 (153k @1p) | 1.7 / 12.3 |

_@≤80% load = the largest ladder rung at ≤80% of peak throughput — the server's service latency with headroom. @saturation = the pinned plateau rung, where a closed-loop fleet measures its own queueing (≈ in-flight ÷ ceiling by Little's law), NOT the server's per-request cost. Compare against the unloaded single-request baseline (~1 ms for wal) before reading anything into large saturation values._

## Saturation walks (pods → ops/s, p50 ms)

- **memory 100000**: 1:186k@1.3ms → 2:388k@1.2ms → 4:526k@1.6ms → 8:544k@2.5ms  (pinned 4, plateau)
- **wal 100000**: 1:43k@5.0ms → 2:40k@9.5ms  (pinned 1, plateau)
- **memory 500000**: 1:153k@1.3ms → 2:259k@1.2ms → 4:323k@1.7ms → 8:299k@2.6ms  (pinned 4, plateau)
- **wal 500000**: 1:29k@6.9ms → 2:30k@14.5ms  (pinned 1, plateau)

## Findings

See [FINDINGS.md](FINDINGS.md) — corrected campaign write-up (memory 6.7-12x wal; latency quoted at the knee, saturation latency labelled as queueing; wal commit-path-bound, not CPU-bound).

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
