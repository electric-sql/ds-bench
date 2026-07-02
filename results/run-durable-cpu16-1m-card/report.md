# run-durable-cpu16-1m-card — write-throughput report

## Throughput at saturation (ops/s)

| streams | cpu16-card-clean |
|---|---|
| 500000 | 1110k† |
| 1000000 | 899k† |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | cpu16-card-clean |
|---|---|
| 500000 | 490 / 441 |
| 1000000 | 962 / 938 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Saturation walks (pods → ops/s)

- **cpu16-card-clean 500000**: 48:1110k  (pinned 48, ladder_exhausted)
- **cpu16-card-clean 1000000**: 32:899k  (pinned 32, ladder_exhausted)

## Findings

_TODO: written by hand on top of the generated data._

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
