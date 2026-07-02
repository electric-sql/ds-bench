# ds-bench full matrix — 2026-07-02 (perf-branch durable build)

Complete campaign on the **perf branch** durable-streams build
(`bench/mixed-interference-validation` @ `330ccd1b0`, code identical to
`perf/combined-t1a-t1c-t2a` head `06a8a37c5` — the delta is a docs-only commit;
PR electric#4679). First campaign to include the **mixed read/write interference
workload**. Hardware: server `c4d-standard-16-lssd` pinned to 4 CPUs, client fleet
`n2d-standard-32` Spot, europe-west4. Versions, images and per-suite details in
`PROVENANCE.md`; per-suite grids in each subdirectory.

## 1. Write saturation (`run-durable`, `run-ursula`, `run-s2`, `run-node`)

Peak append/s at saturation (256 B payloads, saturation pod-ladder per cardinality):

| streams | wal | wal-tailcache | memory | ursula-mem | ursula-disk | node |
|---|---|---|---|---|---|---|
| 100  | 457k | 488k | 436k | 64k  | 2.5k  | 55k |
| 1k   | 655k | 565k | 479k | 111k | 7.0k  | 60k |
| 10k  | 816k | 794k | 575k | 150k | 11.7k | 151k |
| 100k | 1.56M | 1.73M | 732k | — | — | — |
| 200k | 1.50M* | 1.41M* | 534k* | — | — | — |
| 500k | **2.05M** | 1.89M | 1.33M | — | — | — |

- **The wal path clears 2M appends/s at 500k streams on 4 CPUs** — cardinality is
  no longer the limiter it was in the 2026-06-30 baseline (1.48M @ 200k on more
  server cores).
- *200k cells are ladder-shaped, not server ceilings: the 200k ladder tops at 250
  pods vs 500k's 625, and every config reads higher at 500k than 200k. Treat 200k
  as a lower bound; re-walk with a taller ladder if the point matters.
- **`--durability memory` is SLOWER than wal everywhere** (e.g. 575k vs 816k @ 10k
  streams; 1.33M vs 2.05M @ 500k). The wal path's sharded committer outperforms
  the memory path on this branch — worth a look server-side (see also the memory
  delivery collapse in §4).
- s2: 2.0k @ 100 streams; its 1000-stream cell **creation-choked 3× (once from a
  clean slate)** and was dropped from scope — recorded as a gap, not a zero.

## 2. SSE fan-out (`sse-comparison.md` — 1 stream, 50 ev/s, no cache variant)

Delivery latency vs subscriber count (1 stream, 1 writer @ 50 ev/s, writer-paced):

**Delivery p50 (ms)**

| config \ subscribers | 1 | 10 | 100 | 1000 |
|---|---|---|---|---|
| wal (cache off) | 0.359 | 0.482 | 0.905 | 3.645 |
| ursula in-memory | 0.396 | 0.504 | 0.835 | 2.979 |
| ursula disk | 1.307 | 1.822 | 2.135 | 4.247 |

**Delivery p99 (ms)**

| config \ subscribers | 1 | 10 | 100 | 1000 |
|---|---|---|---|---|
| wal (cache off) | 0.577 | 0.717 | 1.276 | 5.079 |
| ursula in-memory | 0.589 | 0.748 | 1.192 | 4.511 |
| ursula disk | 1.528 | 2.261 | 2.761 | 5.867 |

Durable wal stays sub-ms through 100 subscribers — ~2× better than ursula-disk,
on par with ursula-memory. (Single-stream fan-out is a micro-benchmark; the
spread-subscriber story is §4.)

## 3. Read scalability (`reads-catchup`, `reads-sse-remote`; long-poll dropped)

**SSE tail** (`reads-sse-remote`; cell = ops/s @ p99 ms per connection level):

| system, streams | 64 conns | 256 | 1024 | 2048 |
|---|---|---|---|---|
| wal, 10 | 3.2k @ 1.4 | 12.8k @ 2.1 | 51.3k @ 2.6 | 102.5k @ 2.9 |
| wal, 100 | 3.2k @ 1.2 | 12.8k @ 2.3 | 51.3k @ 2.4 | 102.5k @ 2.8 |
| ursula, 10 | 3.2k @ 1.5 | 12.8k @ 1.9 | 51.3k @ 2.7 | 102.5k @ 2.8 |
| ursula, 100 | 3.1k @ 42.2 | 11.8k @ 47.3 | 44.1k @ 56.7 | 80.6k @ 62.9 |

Durable wal is flat across 10 → 100 streams all the way to 2048 concurrent
connections; ursula matches at 10 streams but degrades to p99 ~63 ms at 100
streams.

**Catch-up (hot resident re-scan)** (`reads-catchup`; cell = MiB/s @ p99 ms):

| system, streams | 8 conns | 32 | 128 | 512 |
|---|---|---|---|---|
| wal, 10 | 1345 @ 110.8 | 2381 @ 237.3 | OOM | OOM |
| wal, 100 | 1333 @ 111.7 | 2382 @ 238.2 | OOM | OOM |
| ursula, 10 | 2351 @ 85.9 | 2375 @ 516.6 | OOM | OOM |
| ursula, 100 | OOM | OOM | OOM | OOM |

_OOM cells are the documented client-pod OOM ceiling (AGENTS.md §8) — client-bound
cells, not server data._

Both wal and ursula plateau ~2.4 GiB/s at 32 connections at 10 streams, with
durable holding a ~2× better p99 there (237 ms vs 517 ms); ursula @ 100 streams
OOMs at every level.

## 4. Mixed read/write interference (NEW — `mixed-*`)

Anchor (`mixed-cal`): 50 unthrottled writers → **81.4k ops/s** single-pod mixed-shape
ceiling; sweeps pin writers at ~60% of it.

**Paced readers vs pinned writes** (`mixed-writes`: 10k streams, 10k writers @ 5/s
= 50k ops/s pinned, readers replay once/30 s, staggered, 60 s windows):

| readers | write ops/s | replays/s | read MiB/s | read p50/p99 ms |
|---|---|---|---|---|
| 0 | 49,964 | — | — | — |
| 1,000 | 50,026 | 50 | 3 | 0.49 / 419 |
| 10,000 | 49,826 | 499 | 30 | 0.56 / 404 |
| **100,000** | **50,041** | **4,987** | **304** | 0.52 / 880 |

**The premise holds: 100k concurrent catch-up readers cost the write path
nothing** — throughput is identical to the zero-reader baseline while the server
also serves ~5k replays/s at 304 MiB/s with sub-ms median reads and zero errors.
(Write p99 sits at 350–450 ms at *every* level including zero readers — that is
the single-pod 10k-writer client shape, not reader interference.)

**Unpaced (adversarial) readers** (`mixed-writes-hot`: 50 streams, writers pinned
48.9k ops/s): 16–64 hot readers pull an enormous **~2.3 GiB/s** of replay bandwidth
while writes hold at 48–49k (−2%); at 256 hot readers writes collapse to 7.7k
(−84%). Same cliff as the local validation: bounded read load is free,
*saturating* read load fair-shares everything down — and the server never sheds
(zero 429/503 anywhere).

**Delivery under write load** (`mixed-delivery`: 2000 SSE subscribers spread 1-per-
stream over 2000 streams, write ladder ≈5→100% of ceiling):

| writes/s offered | wal del/s | wal deliv p50/p99 ms | memory del/s | memory deliv p50/p99 ms |
|---|---|---|---|---|
| 4k  | 3.3k  | 0.42 / 163 | 3.9k  | 0.41 / 133 |
| 16k | 13.3k | 0.53 / 15  | 14.7k | 0.63 / 335 |
| 40k | 33.2k | 1.8 / 22   | 15.9k | **227 / 362** |
| 66k | 65.7k | 10.2 / 45  | 20.6k | 207 / 299 |
| max | 65.5k @ 86k writes | 37.9 / 57 | 19.0k @ 62k writes | 201 / 299 |

- **wal: delivery keeps pace to ~66k writes/s** (del/s ≈ writes, p99 ≤ 45 ms);
  at full saturation (86k writes/s) delivery caps at ~65k/s, p99 57 ms.
- **memory: delivery collapses above ~16k writes/s** — subscribers receive only
  16–20k del/s against 40–62k writes with p50 200+ ms. Not the client (the same
  pod did 65k del/s under wal minutes earlier): without WAL commit pacing, the
  fan-out path appears starved. **Server-side finding for the perf branch.**
- The low-rate p99 spike (163 ms at 4k writes/s) tracks the write path's own
  low-rate tail (write p99 138 ms at that level) — commit batching at near-idle,
  not an SSE effect; delivery p99 ≈ write p99 + a few ms throughout.

## Known gaps & artifacts

- s2 @ 1000 streams: dropped (creation_choke ×3, once from clean slate).
- 200k write cells: ladder-bounded lower bounds (see §1).
- `mixed-writes` 1k/100k levels were re-run after Spot-scheduling and fleet-pod
  OOM failures; the OOM fix (fleet memory cap 4 → 24 GiB for ~110k reader tasks +
  per-reader HDR histograms) is in `gke/bench-job.yaml`.
- The campaign was interrupted twice by a 2-hour harness cap on background tasks
  and resumed via `RESUME=1` (no cells lost; ~50 min of cluster-recreation churn).
