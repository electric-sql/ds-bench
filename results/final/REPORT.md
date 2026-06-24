# Write-Throughput Benchmark — Final Results

Maintained final dataset. Per-config data points live in
`results/final/write-throughput/<config>/cells.json`; this report summarizes them.

**Methodology:** single-node, best-case append throughput. 4-CPU-pinned server on
`c4d-standard-16-lssd`; `n2d-standard-32` client fleet (Spot). **256-byte payload per
append**; 15 s warm-up + 20 s measure; saturation walk pins the pod count where
throughput stops gaining ≥5%, median of 3 reps. (SSE: 256-byte events, 1 writer @ 50 ev/s.)

**Builds / provenance (most recent values):**
- **wal** — **new build `47b03a5` ("close WAL read-before-durable")**, `--durability wal
  --wal-shards 4`, `fleet_cpu=0.5`. Prior old-build baseline kept for the regression check below.
- **memory** — `--durability memory` (no WAL; Linux-only zero-copy splice), full sweep at
  `fleet_cpu=2` (4× client CPU recovered the peak vs fc=0.5).
- **ursula in-mem / disk, s2** — unchanged from prior runs (no recent re-run).
- ⚠️ `choke*` = an **intermittent server crash on the rung-restart** (not a ceiling) — see Caveats.

## Peak append throughput (ops/s)

| configuration | peak | at streams | note |
|---|---|---|---|
| **memory** | **~964k** | 100 000 | @`fleet_cpu=2`, @120 pods (degrades to 709k @160); p50 2.06 / p99 978 ms. True peak ~1.005M @`fleet_cpu=1`/200 pods |
| **wal** (new `47b03a5`) | **~692k** | 100 000 | @`fleet_cpu=0.5`; p50 1.88 / p99 1141 ms. prior old-build 754k |
| **ursula in-memory** | ~154k † | 100 000 | ~server-bound ≈150k (lower bound; more clients don't help) |
| **ursula disk** | ~10k | 100 000 | durable Raft fsync bound |
| **s2** | ~2k | 100 | creation-choked at ≥1 000 streams |

## Throughput matrix (ops/s; † = lower bound, `choke*` = rung-restart crash, not a ceiling)

| streams | wal (new) | memory | ursula in-mem | ursula disk | s2 |
|---|---|---|---|---|---|
| 100 | 494k † | 444k | 51k | 4k | 2k |
| 1 000 | 636k | 496k | 86k | 5k | choke |
| 10 000 | choke* | choke* | 106k | 6k | choke |
| 100 000 | **692k** | **964k** | 154k † | 10k | choke |

### Write latency at saturation — p50 / p99 (ms)
At the pinned (saturating) pod count — latencies *under max load* (p99 = queueing tail at the ceiling).

| streams | wal (new) | memory | ursula in-mem | ursula disk | s2 |
|---|---|---|---|---|---|
| 100 | — † | 0.25 / 0.38 | 0.59 / 35.3 | 32.5 / 63.4 | 51.0 / 52.3 |
| 1 000 | 1.24 / 6.87 | 1.58 / 8.0 | 4.40 / 102 | 196.6 / 500.7 | choke |
| 10 000 | choke* | choke* | 14.9 / 474 | 1500 / 4698 | choke |
| 100 000 | 1.88 / 1141 | 2.06 / 978 | 67.3 / 3330 | 6119 / 20005 | choke |

**memory and wal both stay ~sub-ms–2.2ms median** even at saturation; p99 tail grows with the
backlog at the ceiling. ursula in-memory rises into tens of ms; **ursula disk hits hundreds of
ms→seconds** (Raft fsync, p99 ~20s @100k); s2 ~51ms then chokes.

## WAL new build vs prior — regression check

The new build's headline change is *"close WAL read-before-durable + protocol/tier fixes"*.
Per-cardinality (new `47b03a5` @fc0.5 vs prior old build):

| streams | new | prior | Δ | note |
|---|---|---|---|---|
| 100 | 494k † | 504k | −2% | lower bound (ladder exhausted) |
| 1 000 | 636k | 444k | +43% | improved (prior used a lower ladder too) |
| 10 000 | choke* | 629k | — | lost to the rung-restart crash |
| 100 000 | 692k | 754k | −8% | partly `fleet_cpu=0.5` vs prior + run variance |

**Verdict: no clear WAL regression.** n=100/1000 held or improved; the 100k −8% is within the
`fleet_cpu`/run-variance band (memory showed ~18% fc0.5-vs-fc1), not an obvious code regression.
A clean confirmation needs n=10000 (lost to the choke) and a same-`fleet_cpu` baseline.

## SSE fan-out — delivery latency, p50 / p99 (ms)

1 stream, 1 writer @ 50 ev/s, swept total subscribers, single client pod. Writer-paced.
Full spread (p90/p999/max) in `results/final/sse/`.

| subscribers | wal (cache off) | wal (cache on) | ursula in-mem | ursula disk | s2 |
|---|---|---|---|---|---|
| 1 | 0.38 / 0.56 | 0.32 / 0.50 | 0.39 / 0.57 | 0.41 / 0.63 | — |
| 10 | 0.48 / 0.67 | 0.45 / 0.65 | 0.49 / 0.66 | 0.50 / 0.70 | 51.3 / 52.0 |
| 100 | 0.84 / 1.17 | 0.79 / 1.14 | 0.81 / 1.11 | 0.87 / 1.20 | 50.9 / 52.0 |
| 1000 | 3.60 / 5.06 | **2.85 / 4.30** | 2.67 / 3.92 | 2.95 / 4.50 | 52.2 / 54.0 |

- **wal and ursula are competitive** (sub-ms to ~3.6ms median); **residency cache helps SSE** ~15–20%
  at high fan-out (read-path win, unlike writes where it was neutral). **s2 ~51ms — ~10–50× slower.**

## Caveats
- ⚠️ **Intermittent rung-restart choke (open issue, CONFIRMED server-side):** ~1 random cell per
  4-cell sweep is lost to a failure during the pod restart between ladder rungs (rung N completes →
  rung N+1's fleet all-error → 0, recorded as `creation_choke`). It hit **memory @n=1000** (fc=0.5),
  **wal @n=10000** (fc=0.5), and **memory @n=10000** (fc=2). **Giving clients 4× CPU (fc=0.5→2) did not
  fix it — the choke just relocated to a different cardinality**, proving it is **server-side, not
  client-bound** (and not mode- or cardinality-specific). Root cause (OOM vs panic vs restart-readiness
  race) still to be pinned with server-pod logs.
- **memory** column is at `fleet_cpu=0.5`; a `fleet_cpu=2` re-run is in progress (the 1.005M peak was at
  `fleet_cpu=1`). Memory numbers will refresh on completion.
- Single-node, best-case; not multi-node/replicated. ursula/s2 not server-CPU-instrumented.
- Cross-run/cluster variance ~≤20%; trust same-cluster comparisons. Superseded runs in `results/trash/`.
