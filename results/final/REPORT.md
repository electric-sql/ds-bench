# Durable-streams benchmarks — sample run

A single-node run of the four workloads — **write throughput**, **sustained load**,
**catch-up / reconnect**, **SSE fan-out** — across the currently-supported implementations
(**durable-streams**, **ursula**, **S2**). Each workload is a declarative suite under `suites/`;
see *Reproducing* at the end.

**Setup.** Server pinned to 4 CPUs on one node; a Kubernetes client fleet drives load.
256-byte event payloads (1 KiB for catch-up). Latencies are fleet-wide percentiles from
merged HDR histograms. Systems:
- **durable-streams** — `--durability wal` (WAL-backed) and `--durability memory` (no WAL).
- **ursula** — single-node Raft, in-memory (`URSULA_WAL=memory`) and disk WAL.
- **S2 (s2lite)** — object-store-backed.

---

## 1. Write throughput (append/s at saturation)

A saturation walk ramps client pods until per-server throughput plateaus, then pins it.

| streams | durable wal | durable memory | ursula in-mem | ursula disk | s2 |
|---|---|---|---|---|---|
| 100 | 494k | 444k | 51k | 4k | 2k |
| 1 000 | 636k | 496k | 86k | 5k | — |
| 10 000 | 628k | 509k | 106k | 6k | — |
| 100 000 | ~750–870k | **~1.0M** | 154k | 10k | — |

**Peak:** durable-memory **~1.0M append/s**, durable-wal **~750–870k**, ursula-in-memory ~154k,
ursula-disk ~10k, S2 ~2k (S2 stream-creation does not scale past ~100 streams). durable-memory
is ~15–20% faster than durable-wal at the peak (no WAL fsync); durable is ~5× ursula-in-memory
and ~75× ursula-disk.

**Append latency at the peak (p50 / p99, ms):** durable stays sub-ms–2 ms median (p99 tail grows
with the backlog at the ceiling); ursula-in-memory tens of ms; ursula-disk hundreds of ms→seconds
(Raft-log fsync); S2 ~50 ms.

---

## 2. Sustained load (stability over time)

Fixed low rate (10 ops/s × N streams) held for 90 s; measures latency and server-memory drift.

| streams | durable wal: p50 / p99 · RSS drift | durable memory: p50 / p99 · RSS drift |
|---|---|---|
| 10 | 0.52 / 0.89 ms · 0 MiB | 0.44 / 0.72 ms · 0 MiB |
| 50 | 0.61 / 1.33 ms · 2 MiB | 0.55 / 1.11 ms · 2 MiB |
| 100 | 0.59 / 1.69 ms · 4 MiB | 0.44 / 1.07 ms · 3 MiB |
| 150 | 0.52 / 1.55 ms · 5 MiB | 0.44 / 1.18 ms · 2 MiB |

Both modes are **stable** — sub-2 ms latency and ≤5 MiB RSS drift over the window (no leak).
`memory` mode holds RSS as flat as `wal` and runs slightly faster.

---

## 3. Catch-up / reconnect

Reproduces ursula's published methodology (ursula.tonbo.io/benchmark): 1 000 clients each
reconnect to their **own** pre-populated stream and catch up via that system's native path —
**ursula** `GET /bootstrap` (snapshot+tail), **durable** `offset=-1` and **s2** `/records`
(full-log replay). Equal hardware (1 server node each).

| metric (1 KiB events, 200-event streams) | durable | ursula | s2 |
|---|---|---|---|
| per-client catch-up p99 (ms) | 146 | **126** | 331 |
| response body per client (KiB) | 200 | 158 | 471 |
| aggregate replay throughput (MiB/s) | 1306 | 1039 | 1301 |

Ordering: **ursula < durable < s2** — ursula's snapshot+tail reads less (158 KiB vs the full
200/471 KiB), so it finishes fastest; S2's paginated read is slowest. (MiB/s reflects bytes moved,
not speed — ursula moves fewer bytes by design.) durable replays the full log at 200 KiB and
~1.3 GiB/s. At 2 000-event streams durable sustained 925 ms p99 / 2 GiB/s replay.

---

## 4. SSE fan-out (delivery latency)

1 stream, 1 writer @ 50 ev/s, swept total subscribers. Writer-paced; metric is per-event
end-to-end delivery latency (p50 / p99, ms).

| subscribers | durable (cache off) | durable (cache on) | ursula in-mem | ursula disk | s2 |
|---|---|---|---|---|---|
| 1 | 0.38 / 0.56 | 0.32 / 0.50 | 0.39 / 0.57 | 0.41 / 0.63 | — |
| 10 | 0.48 / 0.67 | 0.45 / 0.65 | 0.49 / 0.66 | 0.50 / 0.70 | 51.3 / 52.0 |
| 100 | 0.84 / 1.17 | 0.79 / 1.14 | 0.81 / 1.11 | 0.87 / 1.20 | 50.9 / 52.0 |
| 1000 | 3.60 / 5.06 | 2.85 / 4.30 | 2.67 / 3.92 | 2.95 / 4.50 | 52.2 / 54.0 |

durable and ursula are competitive (sub-ms to ~3.6 ms median across the fan-out). durable's
residency cache helps delivery ~15–20% at high fan-out. **S2 ~50 ms — 10–50× slower** (object-store
delivery path).

---

## Reproducing

Each workload is a suite under `suites/`. Run one with:

    scripts/bench suites/<suite>.json run        # provisions a cluster, runs, tears down
    scripts/bench suites/<suite>.json report      # regenerate the report from local results

- **write throughput** — `suites/write-throughput-{wal,memory,ursula,s2}.json`
- **sustained** — `suites/sustained.json`
- **catch-up** — `suites/catchup-{durable,ursula,s2}.json`
- **SSE fan-out** — `scripts/run-sse.sh`

Raw per-cell data (`cells.json`, merged HDRs) lands under `results/<suite>/`. See `README.md`
for cluster/image setup.

## Tests

The framework logic is unit-tested (no cluster required):

    cd scripts && for t in *_test.py; do python3 "$t"; done
    for t in scripts/*_test.sh; do bash "$t"; done

Covers the suite loader, the per-cell result stores, the saturation classifier, the
catch-up/sustained runners, and the report renderers.
