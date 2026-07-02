# run-durable — write-throughput report

## Throughput at saturation (ops/s)

| streams | wal | wal-tailcache | memory |
|---|---|---|---|
| 100 | 457k | 488k | 436k |
| 1000 | 655k | 565k | 479k |
| 10000 | 816k | 794k | 575k |
| 100000 | 1560k | 1735k | 732k |
| 200000 | 1503k | 1415k | 534k |
| 500000 | 2046k | 1893k | 1329k |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | wal | wal-tailcache | memory |
|---|---|---|---|
| 100 | 95 / 14 | 69 / 68 | 60 / 58 |
| 1000 | 37 / 27 | 56 / 46 | 46 / 37 |
| 10000 | 175 / 75 | 170 / 115 | 151 / 86 |
| 100000 | 915 / 726 | 908 / 706 | 736 / 374 |
| 200000 | 987 / 743 | 775 / 489 | 781 / 311 |
| 500000 | 857 / 513 | 960 / 716 | 752 / 491 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Saturation walks (pods → ops/s)

- **memory 100**: 16:436k → 24:435k  (pinned 16, plateau)
- **wal 100**: 16:457k → 24:482k  (pinned 16, plateau)
- **wal-tailcache 100**: 16:451k → 24:488k → 32:519k  (pinned 24, plateau)
- **memory 1000**: 16:479k → 24:471k  (pinned 16, plateau)
- **wal 1000**: 16:587k → 24:655k → 32:690k  (pinned 24, plateau)
- **wal-tailcache 1000**: 16:565k → 24:604k  (pinned 16, plateau)
- **memory 10000**: 32:575k → 48:616k  (pinned 32, plateau)
- **wal 10000**: 32:816k → 48:863k  (pinned 32, plateau)
- **wal-tailcache 10000**: 32:794k → 48:753k  (pinned 32, plateau)
- **memory 100000**: 80:732k → 100:407k  (pinned 80, plateau)
- **wal 100000**: 80:811k → 100:1560k → 110:503k  (pinned 100, plateau)
- **wal-tailcache 100000**: 80:1735k → 100:516k  (pinned 80, plateau)
- **memory 200000**: 100:534k → 160:378k  (pinned 100, plateau)
- **wal 200000**: 100:1503k → 160:1603k  (pinned 100, plateau)
- **wal-tailcache 200000**: 100:1415k → 160:1192k  (pinned 100, plateau)
- **memory 500000**: 250:1224k → 400:1329k → 625:361k  (pinned 400, plateau)
- **wal 500000**: 250:2046k → 400:1829k  (pinned 250, plateau)
- **wal-tailcache 500000**: 250:1893k → 400:1590k  (pinned 250, plateau)

## Findings

_TODO: written by hand on top of the generated data._

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
