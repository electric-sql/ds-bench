# run-node — write-throughput report

## Throughput at saturation (ops/s)

| streams | node |
|---|---|
| 100 | 55k |
| 1000 | 60k |
| 10000 | 151k |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | node |
|---|---|
| 100 | 245 / 171 |
| 1000 | 393 / 290 |
| 10000 | 803 / 651 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Saturation walks (pods → ops/s)

- **node 100**: 4:55k → 8:58k  (pinned 4, plateau)
- **node 1000**: 4:60k → 8:62k  (pinned 4, plateau)
- **node 10000**: 8:116k → 16:151k → 24:87k  (pinned 16, plateau)

## Findings

_TODO: written by hand on top of the generated data._

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
