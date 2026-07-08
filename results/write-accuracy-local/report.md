# write-accuracy-local — write-throughput report

## Throughput at saturation (ops/s)

| streams | wal | memory |
|---|---|---|
| 2000 | 65k† | 147k |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | wal | memory |
|---|---|---|
| 2000 | 35 / 26 | 37 / 25 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Saturation walks (pods → ops/s)

- **memory 2000**: 2:147k → 4:140k  (pinned 2, plateau)
- **wal 2000**: 2:43k → 4:65k  (pinned 4, ladder_exhausted)

## Findings

_TODO: written by hand on top of the generated data._

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
