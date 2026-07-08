# write-wal-vs-mem-cpu8 — write-throughput report

## Throughput at saturation (ops/s)

| streams | wal | memory |
|---|---|---|
| 100000 | 69k | 484k |
| 500000 | 47k | 322k |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | wal | memory |
|---|---|---|
| 100000 | 676 / 596 | 1260 / 837 |
| 500000 | 2607 / 2419 | 2910 / 2020 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Saturation walks (pods → ops/s)

- **memory 100000**: 16:349k → 24:442k → 32:484k → 48:418k  (pinned 32, plateau)
- **wal 100000**: 16:69k → 24:68k  (pinned 16, plateau)
- **memory 500000**: 16:322k → 24:277k  (pinned 16, plateau)
- **wal 500000**: 16:47k → 24:49k  (pinned 16, plateau)

## Findings

See [FINDINGS.md](FINDINGS.md) — combined campaign write-up (memory 4.5-7x wal; wal commit-path-bound, not CPU-bound; every cell windows_aligned).

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
