# write-wal-vs-mem-cpu4 — write-throughput report

## Throughput at saturation (ops/s)

| streams | wal | memory |
|---|---|---|
| 100000 | 47k | 315k |
| 500000 | 31k | 226k |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | wal | memory |
|---|---|---|
| 100000 | 613 / 519 | 631 / 569 |
| 500000 | 2469 / 2162 | 2876 / 2076 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Latency (ms, p50 / p99)

| streams | wal @≤80% load | wal @saturation | memory @≤80% load | memory @saturation |
|---|---|---|---|---|
| 100000 | 4.5 / 35.8 (38k @1p) | 8.5 / 35.5 | 1.2 / 2.4 (204k @1p) | 1.3 / 17.2 |
| 500000 | 6.7 / 26.9 (31k @1p) | 6.4 / 23.3 | 1.1 / 2.3 (165k @1p) | 1.3 / 18.4 |

_@≤80% load = the largest ladder rung at ≤80% of peak throughput — the server's service latency with headroom. @saturation = the pinned plateau rung, where a closed-loop fleet measures its own queueing (≈ in-flight ÷ ceiling by Little's law), NOT the server's per-request cost. Compare against the unloaded single-request baseline (~1 ms for wal) before reading anything into large saturation values._

## Saturation walks (pods → ops/s, p50 ms)

- **memory 100000**: 1:204k@1.2ms → 2:315k@1.3ms → 4:319k@2.2ms  (pinned 2, plateau)
- **wal 100000**: 1:38k@4.5ms → 2:47k@8.4ms → 4:46k@17.8ms  (pinned 2, plateau)
- **memory 500000**: 1:165k@1.1ms → 2:226k@1.4ms → 4:206k@2.2ms  (pinned 2, plateau)
- **wal 500000**: 1:31k@6.7ms → 2:28k@16.1ms  (pinned 1, plateau)

## Findings

See [FINDINGS.md](FINDINGS.md) — corrected campaign write-up (memory 6.7-12x wal; latency quoted at the knee, saturation latency labelled as queueing; wal commit-path-bound, not CPU-bound).

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
