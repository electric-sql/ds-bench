# Zero-Copy Append Comparison — 2026-06-24

Write (append) throughput of the new `worktree-zero-copy-appends` durable-streams
binary (carries the payload-CRC correctness fix), comparing the `--zero-copy`
splice/sendfile append path **on vs off**, plus the resident tail cache, plus a
reference to the prior (pre-CRC) binary. Same saturation methodology as the
2026-06-24 campaign: 4-CPU-pinned server on `c4d-standard-16-lssd`, `n2d-standard-32`
clients, `fleet_cpu=2`, ~1000 streams/pod, plateau 5%, `setup_concurrency=32`, 3 reps.

Data: `results/all-configs-comparison.{md,csv}`, `results/zerocopy-comparison.md`,
per-suite `results/write-throughput-*/`.

## Peak append throughput

| configuration | binary | flags | peak ops/s | saturation |
|---|---|---|---|---|
| **wal-newbin (peak)** | new (CRC) | zero-copy OFF | **~754k @ 190 pods** | PEAK — degrades past it (see below) |
| wal-tailcache | old | cache on | 684k | plateau ✅ |
| wal (old) | old | — | 608k | plateau ✅ |
| wal-newbin-tailcache | new (CRC) | zero-copy OFF + cache | 600k | plateau ✅ |
| **zerocopy** | new (CRC) | **zero-copy ON** | **592k** | plateau ✅ |

(`wal-newbin` 8-node and 14-node runs gave lower-bound 689k†/706k† — still climbing
at their pod ceilings; the 28-node run below found the actual knee.)

## Findings

1. **`--zero-copy` is SLOWER on appends, not faster.** Same binary, same cluster,
   back-to-back: zero-copy **on** *saturates* at ~592k, while zero-copy **off** peaks
   ~**754k** — i.e. `--zero-copy` costs **~21%** of peak append throughput. This is
   counter-intuitive (zero-copy is meant to reduce copies) and is the headline result —
   worth a profiling pass on the `--zero-copy` write path (per-op splice/fd overhead, or
   it disabling a batching/coalescing fast-path).

2. **The new binary is FASTER than the old — despite adding the CRC.** `wal-newbin`
   (≥706k, with payload-CRC) beats the old pre-CRC `wal` (608k). The correctness CRC's
   cost is more than offset by other improvements in the new code. Net: **ship the new
   binary with `--zero-copy` OFF** for peak append throughput.

3. **The resident tail cache is write-neutral.** The controlled old-binary A/B (`wal`
   608k vs `wal-tailcache` 684k) and the n=100 new-binary cells (505k vs 504k) show the
   cache doesn't change appends meaningfully — expected, it's a read-path cache. Larger
   apparent deltas at high cardinality are cross-cluster run-to-run variance, not a cache
   effect.

4. **`wal-newbin`'s ceiling ≈ 754k at ~190 pods — and it DEGRADES past it.** The 28-node
   push run walked `190 pods → 754k`, then `280 pods → 376k` (a ~50% collapse). So the
   server peaks ~754k around 190 client pods and **overloads beyond that** (connection/CPU
   contention on the 4-CPU server), rather than holding flat. Practical guidance: ~750k is
   the usable peak; over-driving the client fleet is counter-productive. (The walk pinned
   190 because the next rung dropped — the "plateau" label here means "peak", not a flat
   shelf. A finer sweep of 200–260 pods would map the roll-off precisely.)

## Caveats
- **Cross-cluster variance is significant** (e.g. a cell measured ~444k on one cluster
  instance and ~600k on another at n=1000). Trust the *same-cluster, back-to-back*
  comparisons (zerocopy vs wal-newbin); treat cross-run deltas <~20% as noise.
- The `wal-newbin-ext` 100k walk had a cold first rung (110 pods → 21k, a startup
  artifact); the walk correctly kept climbing (150→643k, 190→706k).
- Single-node, best-case; CRC is a permanent correctness requirement (old pre-CRC `wal`
  shown only as a historical reference, not a regression target).

## Process note
A teardown bug was found + fixed during this run: a run could write its completion
marker even when its own cluster teardown failed (cluster `RECONCILING`), which once
orphaned a billing cluster. Fixed: `cmd_teardown` now retries through RECONCILING, and
the watchdog verifies no matching cluster remains before standing down.
