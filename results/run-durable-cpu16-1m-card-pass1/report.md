# run-durable-cpu16-1m-card — write-throughput report

## Throughput at saturation (ops/s)

| streams | cpu16-card-clean |
|---|---|
| 500000 | ERROR (creation_choke) |
| 1000000 | 1115k† |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | cpu16-card-clean |
|---|---|
| 500000 | — |
| 1000000 | 857 / 705 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Saturation walks (pods → ops/s)

- **cpu16-card-clean 500000**: 48:0k  (pinned None, creation_choke)
- **cpu16-card-clean 1000000**: 32:764k → 48:923k → 64:1115k  (pinned 64, ladder_exhausted)

## Findings

_TODO: written by hand on top of the generated data._

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
