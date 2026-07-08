# write-wal-vs-mem-cpu4 — write-throughput report

## Throughput at saturation (ops/s)

| streams | wal | memory |
|---|---|---|
| 100000 | 59k | 297k |
| 500000 | 48k | 216k |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | wal | memory |
|---|---|---|
| 100000 | 671 / 590 | 629 / 573 |
| 500000 | 2727 / 2627 | 2783 / 2018 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Saturation walks (pods → ops/s)

- **memory 100000**: 8:297k → 16:277k  (pinned 8, plateau)
- **wal 100000**: 8:51k → 16:59k → 24:63k  (pinned 16, plateau)
- **memory 500000**: 8:216k → 16:208k  (pinned 8, plateau)
- **wal 500000**: 8:39k → 16:44k → 24:48k → 32:41k  (pinned 24, plateau)

## Findings

See [FINDINGS.md](FINDINGS.md) — combined campaign write-up (memory 4.5-7x wal; wal commit-path-bound, not CPU-bound; every cell windows_aligned).

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
