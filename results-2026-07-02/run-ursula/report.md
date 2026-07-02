# run-ursula — write-throughput report

## Throughput at saturation (ops/s)

| streams | ursula-memory | ursula-disk |
|---|---|---|
| 100 | 64k | 2k |
| 1000 | 112k† | 7k |
| 10000 | 150k | 12k |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | ursula-memory | ursula-disk |
|---|---|---|
| 100 | 2613 / 2076 | 1098 / 1053 |
| 1000 | 2481 / 2054 | 1655 / 1515 |
| 10000 | 3482 / 2899 | 2487 / 2259 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Saturation walks (pods → ops/s)

- **ursula-disk 100**: 4:2k → 8:2k  (pinned 4, plateau)
- **ursula-memory 100**: 4:64k → 8:66k  (pinned 4, plateau)
- **ursula-disk 1000**: 4:7k → 8:5k  (pinned 4, plateau)
- **ursula-memory 1000**: 4:79k → 8:104k → 16:112k  (pinned 16, ladder_exhausted)
- **ursula-disk 10000**: 8:9k → 16:12k → 24:11k  (pinned 16, plateau)
- **ursula-memory 10000**: 8:120k → 16:150k → 24:131k  (pinned 16, plateau)

## Findings

_TODO: written by hand on top of the generated data._

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
