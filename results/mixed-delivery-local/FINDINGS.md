# mixed-delivery-local — does write load hurt live SSE delivery? (local kind validation)

**Setup (v2, 2026-07-02).** durable server built from `electric-ds-rust`
`bench/mixed-interference-validation` (off `perf/combined-t1a-t1c-t2a`), local kind
(server 2 CPU / 2 Gi), 50 shared streams, **100 SSE subscribers fixed** (2/stream), no
catch-up readers. Sweep: per-writer rate 30/120/300/475/unthrottled ≈ **5/20/50/80/100%
of the 29.7k ops/s local ceiling** (`mixed-cal-local`). Two server configs: `wal`
(default) and `memory` (`--durability memory`) to separate commit cost from fan-out
cost. Delivery counters now split data vs control frames — `deliv rec/s` is true
per-record deliveries; rates divide by the barrier-aligned drive window.

| rate/writer | wal: write ops/s | wal: write p50/p99 | wal: deliv rec/s | wal: deliv p50/p99 | mem: write ops/s | mem: write p50/p99 | mem: deliv rec/s | mem: deliv p50/p99 |
|---|---|---|---|---|---|---|---|---|
| 30  | 1502  | 2.4 / 9.7  | 3005  | 3.2 / 12.4 | 1502  | 0.7 / 5.7  | 3005  | 1.4 / 8.7 |
| 120 | 6002  | 0.7 / 7.9  | 12003 | 0.9 / 10.1 | 6002  | 0.4 / 2.1  | 12000 | 0.8 / 3.5 |
| 300 | 14741 | 1.7 / 13.8 | 29475 | 2.1 / 17.2 | 15001 | 0.4 / 2.7  | 29477 | 0.9 / 5.1 |
| 475 | 17380 | 2.3 / 19.1 | 34746 | 2.8 / 20.9 | 23752 | 0.6 / 3.8  | 44982 | 1.3 / 8.5 |
| max | 17144 | 2.3 / 20.3 | 34273 | 2.8 / 22.6 | 29247 | 1.2 / 30.0 | 44328 | 3.3 / 34.8 |

## Conclusions vs the premise

1. **Delivery latency still doesn't degrade meaningfully with write load.** wal delivery
   p99 moves 10–23 ms across a 16× load increase (p50 ≤ 3.2 ms); memory-durability holds
   p99 at 3.5–8.7 ms up to 80% of ceiling. The live SSE path keeps pace: deliveries are
   exactly 2× writes (2 subscribers/stream) at every level below saturation.
2. **The v1 "~14 ms delivery floor" is WAL commit (fsync) cost, not the SSE path.**
   At matched mid loads, wal p99 ≈ 10–17 ms vs memory ≈ 3.5–5.1 ms, and in BOTH configs
   delivery p99 ≈ write p99 + **~1–3 ms** — the fan-out itself is cheap. No server-side
   SSE change is warranted from this validation. (A small residual low-rate bump exists
   even in memory mode — p99 8.7 ms at 5% load vs 3.5 ms at 20% — sub-10 ms and likely
   local-VM timer/TCP effects; re-check on remote hardware before chasing it.)
3. **Fan-out tax on the write ceiling (wal): ~42%** — 29.7k solo → 17.1–17.4k with 100
   subscribers on 2 CPUs. Larger than v1's 24% because the faster perf-branch server
   makes the fan-out share of CPU relatively bigger. Memory config reached 29.2k with
   subscribers attached, but at that extreme deliveries lagged writes (44.3k rec/s <
   2×29.2k) with p99 34.8 ms — the only level where subscribers fell behind, and the
   single client pod (parsing ~44k events/s while driving ~29k appends/s) is a suspect.

## Validity caveats

- Single-node kind co-location; absolute numbers (esp. the saturated `memory` level and
  the 42% tax) need a remote run with separated node pools.
- Windows are 20 s; the memory `max` level's 30 ms write p99 hints at allocator/GC-like
  burst behaviour worth a longer sustained look when promoted.

## Status for promotion

Metric blockers from v1 are fixed (control-frame split, drive-window rates). The suite
shape is promotion-ready: one axis, %-of-ceiling levels, per-config columns. For the
remote suite: derive levels from each system's `run-*` saturation peak, keep the
`wal` + `memory` pair (it splits commit cost from fan-out cost for free), and consider
`pods > 1` or a subscriber-only pod to rule the client out at saturated levels.

Companion: `results/mixed-writes-local/FINDINGS.md`. Raw grid: `report.md` /
`aggregate.{csv,json}` here; suite: `suites/mixed-delivery-local.json`.
