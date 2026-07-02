# durable-streams wal — cardinality fixes at 16 vCPU: 1M streams reaches 1.11M ops/s

**Date:** 2026-07-02 · **Server:** `c4d-standard-16-lssd`, `SERVER_CPUS=16`,
`--durability wal --wal-shards 16 --worker-threads 16` (on-demand) · **Client:** pool
model, 6× `n2d-standard-32` (Spot), `CONNS_PER_POD=256`, `batch:1`, 256 B payload.

**Server build:** `perf/combined-t1a-t1c-t2a` @ `662b0c845` — the combined Tier-1/2
stack **plus the 2026-07-02 cardinality fixes** (O(1) dirty-set drain, checkpoint fully
off-runtime + concurrent across shards, resident tails map, per-append meta sidecar
flush moved to the checkpoint, single registry lookup per append). Image
`durable-streams:combined-card@sha256:d74840bd…`. Direct baseline:
`run-durable-cpu16-1m-p99-combined` (image @ `f04baa64e`, 2026-07-01).

## TL;DR — the goal rung: ≥1M ops/s at 1M streams on 16 vCPU

| streams | pods (conns) | ops/s | p50 | p90 | p99 | p99.9 | max |
|---|---|---|---|---|---|---|---|
| 1,000,000 | 32 (8,192) | **898,582** | 3.5 ms | 23.8 | 30.5 | 48.2 | **149.6 ms** |
| 1,000,000 | 48 (12,288) | **922,831**† | 5.2 ms | 22.0 | 60.7 | 89.7 | 3377 ms† |
| 1,000,000 | 64 (16,384) | **1,114,644** | 3.4 ms | 51.5 | 60.3 | 69.5 | **211.1 ms** |
| 500,000 | 48 (12,288) | **1,110,268** | 3.1 ms | 35.1 | 42.7 | 53.2 | 145.0 ms |

† p48 ran during pass 1 while the client node pool was still stabilizing after a
manual repair (see Caveats); treat its tail as an upper bound.

- **The ladder is `ladder_exhausted`, not saturated** — 1M streams was still climbing
  at 64 pods (+21% per +16 pods). 1.11M ops/s is a floor for this box, not the ceiling.
- **vs baseline at the same 32-pod rung:** 862k → 899k ops/s (fixed-concurrency, so
  the rung is latency-bound: mean 9.5 → 9.1 ms), but the tail collapsed:
  max **405 ms → 149.6 ms** (and the 8 vCPU baseline's 3.3 s outliers are gone),
  p99.9 88 → 48 ms. The baseline had no headroom past ~862k (80%-CPU coordination
  ceiling); the fixed build does 1.11M+.
- **The 500k→1M cardinality cliff is now shallow:** at the same 48-pod load,
  1,110k → 923k = **−17% for 2× streams** (and −0.4% at the 64-pod rung vs 500k@48).
  Server pod RSS at 1M streams: ~0.96 GB.

## What changed (server, commit 662b0c845)

Root causes found on a local Linux repro (see
`packages/durable-streams-rust/scripts/contention-repro-linux.sh`; local A/B at 400k
streams: 16.0k → ~44k ops/s, p99 144 → 27 ms):

1. **Checkpoint drain held the shard dirty-mutex during O(touched) work.** At high
   cardinality ops/stream/interval < 1, so *every* append takes the epoch-transition
   path through that mutex — the 25–140 ms drain stalls every appender on the shard.
   Now the critical section is take + epoch-bump only.
2. **Checkpoint phases ran on async runtime threads** (capture, cumulative tails-file
   re-read/rewrite, recycle; only the fsyncs were off-thread). Now the whole
   checkpoint body is one `spawn_blocking`, shards checkpoint concurrently, and the
   tails map is memory-resident (no per-tick re-read/parse/sort of an O(streams) file).
3. **Per-append meta sidecar flush** (`File::create(.meta.tmp)` + `rename` per append
   once inter-append gap > the 100 ms debounce — i.e. always, at high cardinality):
   all workers spun on the data-dir inode rwsem — **~40% of server CPU in perf, at
   every cardinality**. WAL-staged appends now just mark `meta_dirty`; the checkpoint
   writes sidecars for drained streams after recycle. Producer/access sidecar state
   was already a documented non-durable lagging flush; the lag bound moves from
   ~100 ms to the checkpoint cadence.
4. **Redundant second registry lookup per append** (metrics label) — removed.

Correctness: 95 crate unit/e2e tests + 326 server-conformance tests pass.

## Caveats / provenance

- Pass 1 (`run-durable-cpu16-1m-card-pass1/`): the initial cluster came up without
  its client node pool (an interrupted first launch); the pool was created manually
  mid-run. Its 500k cell errored (`creation_choke`, fleet unschedulable) and its 1M
  p32 rung (764k) is contaminated by fleet pods starting while nodes were still
  joining. Pass 2 (this dir) re-ran 500k@48 and 1M@32 cleanly on the stable fleet;
  1M p48/p64 come from pass 1 *after* the pool was stable.
- The planned `--wal-stats` telemetry cell (`run-durable-cpu16-1m-card-stats.json`)
  did not run — the teardown watchdog hit its 4 h deadline (correctly) after the
  clean cells finished. Open question it would have answered: `WAL_CKPT` phase times
  on real NVMe at 1M streams (checkpoint meta writes/s ≈ ops/s at full cardinality —
  fine locally on tmpfs, worth confirming on NVMe before pushing past ~1.5M ops/s).
- Cluster: `bench-wal` (europe-west4-a), deleted; verified
  `gcloud container clusters list` empty at 04:14Z.

## Follow-ups (in value order)

1. **Find the true 16 vCPU ceiling at 1M streams** — extend the ladder past 64 pods
   (needs ≥7 client nodes) or run 32 vCPU.
2. **Per-shard producer-state journal** — sidecar writes/s ≈ ops/s at full cardinality
   (now off the hot path, but it bounds checkpoint cadence / producer-state staleness
   and burns blocking-thread CPU). One cumulative per-shard file per tick (like
   `tails`) makes it O(1) files/tick; needs a recovery overlay (merge producers by
   max(epoch, seq)).
3. **Read+write mix at 1M streams** — still write-only; the meta-flush change also
   removes read-path interference from the append path, but verify.
4. Re-run the stats cell for NVMe `WAL_CKPT` numbers.
