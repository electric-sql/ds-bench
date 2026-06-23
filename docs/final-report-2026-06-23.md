# Single-node streaming benchmark — durable-streams vs ursula vs S2 Lite (2026-06-23)

One server node, **cgroup-pinned to 4 CPU** (c4d-standard-16-lssd, single Titanium NVMe), object/cold tier = in-cluster MinIO for all three systems. Client fleet on GKE (n2d-standard-32 nodes for the driven runs). This is a **single-node, best-case** comparison — **not** ursula's 3-voter Raft quorum. `durable:fast` (ack-on-page-cache, no fsync) was **removed** mid-investigation: wal is faster *and* durable, so fast had no purpose.

## Methodology caveat (read this first)

Write throughput here is **strongly client-load-dependent**, and the "right" client fleet differs per system:
- **wal / s2** stay client-bound until driven very hard (numbers rose at every step: more pods → higher throughput).
- **strict** is the opposite — a *heavy* client fleet makes its per-stream fsync storm collapse it *earlier*.
- **ursula** is server-bound (Raft-WAL ceiling), unmoved by fleet size.

So the write table reports each system's **best-driven (near-ceiling) number**, with the caveat that these are lower bounds for the client-bound systems. **`cpu_pct` is unreliable at high cardinality** (reads 30–50% at 400k+ ops/s) — we trust throughput, not CPU. A few cells produced occasional **collapse reps** (a fresh-deploy thrash); medians are reported.

## WRITE — multi-stream throughput (ops/s, near-ceiling)

| streams | **durable:wal** | durable:strict | durable:strict-iouring | ursula:memory | ursula:disk | s2 |
|---|---|---|---|---|---|---|
| **1k** | **~510k** | ~100k | ~106k | ~67k | ~62k | ~19k |
| **10k** | **~635k** | cliff (≤34k → collapse) | cliff | ~76k | ~71k | ~80k |
| **100k** | **~382k** | collapse (~0) | collapse (~0) | ~86k | ~90k | ~100k |

- **durable:wal is the headline — peaks ~635k @ 10k, ~510k @ 1k, ~382k @ 100k.** Cardinality-robust (the sharded WAL batches fsyncs across streams). Earlier "200k @ 100k / 495k @ 10k" figures were **client-bound** — driving harder lifted them.
- **Matched durability** (both fsync-per-commit): durable:wal vs **ursula:disk** ≈ **9× @ 10k** (635k vs 71k), **~4× @ 100k** (382k vs 90k). ursula:memory (no fsync, best case) is ~67–86k — durable:wal beats even ursula's non-durable mode by ~6–9×.
- **strict / strict-iouring don't scale.** Per-stream group-commit fsync issues ~one `fdatasync` per append with no cross-stream batching; at high stream count (or high concurrent load) the disk can't drain the queue, the server **thrashes** (CPU busy, throughput ~0, **p99 ≈ 20s**). io_uring makes it *worse*, not better. Confirmed not a warmup artifact (60s warmup → still ~0). strict is fine only at low cardinality **and** moderate load.
- **ursula is server-bound** (~62–91k, flat regardless of client fleet) — its Raft-WAL is the limit. **s2 is client-bound** and scales to ~100k @ 100k with enough pods — its earlier "0 @ 100k" was under-provisioning, **not** an object-store limit.

## SSE — fan-out delivery latency (p99, ms)

| subscribers | **durable:wal** (cache off) | durable:wal-cache (cache **on**) | ursula:memory | ursula:disk | s2 |
|---|---|---|---|---|---|
| 1 | **0.49** | — | 1.0 | 2.2 | 52 |
| 10 | **0.75** | 0.64 | 1.0 | 2.7 | 52 |
| 100 | **1.27** | 1.09 | 1.7 | 2.5 | 52 |
| 1000 | 5.0 | **3.9** | 5.1 | 5.6 | 54 |

- **durable:wal owns delivery latency** (sub-ms to 5ms); **S2 is ~10–50× worse (~52ms)** — SSE isn't object-store-native.
- **Tail cache is marginal**: slightly *better* at high fan-out (1000 subs: 3.9 vs 5.0ms), neutral/worse at low. The Linux default (off, sendfile) is the right default; the cache is a small win only for large fan-outs. (SSE is 1-rep — indicative.)

## REPLAY — catch-up latency (p99, ms; throughput N/A for a one-shot)

| durable:wal | ursula:memory | ursula:disk |
|---|---|---|
| ~210–790 (noisy) | ~200 | ~450 |

ursula:memory leads; durable:wal in range but noisy; durable beats ursula:disk. (S2 excluded — its paginated native replay isn't comparable.)

## Findings

1. **WAL is the scalable durable write path** (~510–635k, cardinality-robust); **strict's per-stream fsync collapses** at high cardinality or load. This is *the* architectural result.
2. **Durability-matched, durable wins decisively**: ~9× ursula:disk @ 10k, ~4× @ 100k; ~6–9× even vs ursula:memory's no-fsync best case.
3. **durable:wal has the best SSE delivery latency**; S2 an order of magnitude behind; tail cache a marginal high-fan-out win.
4. **Most ceilings here are client-bound, not server limits** — wal, s2 kept rising with more client; only ursula and (artificially) strict are server-bound. Driving hard matters more than any tuning.
5. **`fast` mode removed** — no throughput benefit over wal, and not durable.
6. **Operational limits surfaced:** stream-creation chokes at ~200–300 concurrent pods (`PUT /v1/stream` drops connections); MinIO result-collection needs ≥2–4 CPU at high pod counts; `cpu_pct` instrumentation is unreliable above ~10k streams.

## Caveats

Best-case single-node on local NVMe — **not** ursula's 3-node Raft quorum (its headline feature, deliberately stripped because durable-streams has no multi-node yet). Object tier = in-cluster MinIO for all. `cpu_pct`/`mem` instrumented for durable only. Write throughput is load-dependent (numbers are near-ceiling/lower bounds for the client-bound systems). Driven on a fleet large enough to be client-unbound where possible; some 100k cells limited by the stream-creation choke.
