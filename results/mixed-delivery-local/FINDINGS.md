# mixed-delivery-local — does write load hurt live SSE delivery? (local kind validation)

**Setup.** durable `wal`, local kind (server 2 CPU / 2 Gi), 50 shared streams, **100 SSE
subscribers fixed** (2 per stream), no catch-up readers. Sweep: per-writer append rate
20 / 80 / 200 / 315 / unthrottled ≈ **5% / 20% / 50% / 80% / 100% of the measured local
write ceiling** (19.6k ops/s from `mixed-cal-local`). 20 s windows, 256 B payloads,
fresh server per level. Delivery latency = writer-embedded timestamp → subscriber receipt.

| rate/writer (offered total) | write ops/s | write p50/p99 ms | deliv frames/s | deliv p50/p99 ms |
|---|---|---|---|---|
| 20 (1k)      | 909   | 2.0 / 12.9 | 3639  | 2.3 / 14.1 |
| 80 (4k)      | 3628  | 1.2 / 14.9 | 14515 | 1.4 / 16.8 |
| 200 (10k)    | 9073  | 1.4 / 11.8 | 36294 | 1.7 / 13.7 |
| 315 (15.75k) | 13562 | 2.7 / 14.7 | 54242 | 3.2 / 17.3 |
| max          | 14883 | 2.6 / 12.8 | 59528 | 3.0 / 14.0 |

## Conclusions vs the premise

1. **Delivery latency is flat all the way to write saturation.** Delivery p99 stays in a
   13.7–17.3 ms band (p50 1.4–3.2 ms) across a 16× increase in write load, including the
   fully saturated level. Premise 2 ("the streamed tail path keeps per-event delivery flat
   as writes approach the ceiling") is **confirmed** on this deployment.
2. **Delivery kept pace exactly — no lag or drops.** Frames/s is exactly 4.0× write ops/s at
   every level = 2 subscribers/stream × 2 SSE frames per record (each record arrives as a
   timestamped data frame plus an untimestamped control frame — see caveat below). True
   per-record delivery is therefore exactly 2× writes, i.e. every subscriber saw every append.
3. **The interference runs the other way: fan-out costs the write path ~24%.** The write
   ceiling with 100 subscribers attached is 14.9k ops/s vs 19.6k solo, and the 315/s level
   already misses its offered rate (13.6k < 15.75k). Fan-out work contends with append work.
4. **Delivery p99 has a ~14 ms floor independent of load** (present even at 5% load, where
   the server is nearly idle) — it looks like a wakeup/flush cadence constant, not queueing.
   Worth understanding before quoting the number.

## Validity caveats

- **`events_per_sec` double-counts**: `mixed.rs` counts non-data SSE control frames
  (`sse_reactor` sends data + control per batch). Latency histograms only record timestamped
  data frames, so the p50/p99 are sound; the rate metric should be halved or the counters split.
- **Single-node kind co-location** (client + server + MinIO share one VM): the flat-latency
  *shape* is trustworthy; absolute numbers and the 24% fan-out tax need a remote run.
- Rates include setup in the elapsed window, slightly understating drive-window ops/s.

## Before promoting to the full suite

- Split `events_received` into data vs control frames in `ds-bench mixed`.
- Derive sweep levels from each system's measured saturation peak (%-of-ceiling levels) so the
  suite is cross-implementation fair; pair with `run-*` write-saturation results.
- This combination is otherwise promotion-ready: single clean axis, crisp claim
  (delivery p99 vs write-load fraction), directly comparable across implementations.

Companion: `results/mixed-writes-local/FINDINGS.md` (the opposite interference direction).
Raw grid: `report.md` / `aggregate.{csv,json}` in this directory; suite: `suites/mixed-delivery-local.json`.
