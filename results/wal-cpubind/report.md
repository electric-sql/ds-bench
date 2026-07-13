# wal-cpubind — write-throughput report

## Throughput at saturation (ops/s)

| streams | bound-3s |
|---|---|
| 10000 | 370k† |
| 100000 | 328k |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | bound-3s |
|---|---|
| 10000 | 249 / 198 |
| 100000 | 694 / 596 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Latency (ms, p50 / p99)

| streams | bound-3s @≤80% load | bound-3s @saturation |
|---|---|---|
| 10000 | 2.5 / 5.2 (370k @4p) | — |
| 100000 | 1.3 / 2.8 (325k @2p) | 1.3 / 2.8 |

_@≤80% load = the largest ladder rung at ≤80% of peak throughput — the server's service latency with headroom. @saturation = the pinned plateau rung, where a closed-loop fleet measures its own queueing (≈ in-flight ÷ ceiling by Little's law), NOT the server's per-request cost. Compare against the unloaded single-request baseline (~1 ms for wal) before reading anything into large saturation values._

## Saturation walks (pods → ops/s, p50 ms)

- **bound-3s 10000**: 4:370k@2.5ms → 8:356k@5.4ms  (pinned 8, ladder_exhausted)
- **bound-3s 100000**: 2:325k@1.3ms → 4:342k@2.6ms → 8:318k@5.5ms  (pinned 2, plateau)

## Findings

Exclusive pinned cores (STATIC_CPU=1 + GUARANTEED=1, cpuManagerPolicy=static, integer 8-CPU Guaranteed pod) = 356.0k @10k / 328.0k @100k vs 286.3k/271.6k on shared cores (wal-splitlane ref-3s, same layout/image/args): +24% / +21%. With wal no longer fsync-bound, CPU binding is a real lever. Caveat: cross-cluster comparison (bench-cpubind vs bench-multilane), same instance type/zone.

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
