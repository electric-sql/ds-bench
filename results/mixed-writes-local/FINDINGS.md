# mixed-writes-local — do catch-up readers hurt a pinned write load? (local kind validation)

**Setup.** durable `wal`, local kind (server 2 CPU / 2 Gi), 50 shared streams, 1 writer/stream
pinned at 240 appends/s each = **12k ops/s offered ≈ 61% of the measured local ceiling**
(19.6k ops/s, from `mixed-cal-local`: 50 unthrottled writers, p50 2.1 ms / p99 10.4 ms).
Sweep: catch-up readers 0 → 128, each an **unpaced hot loop** replaying its stream from
offset 0. 20 s windows, 256 B payloads, fresh server per level.

| readers | write ops/s (of 12k pinned) | write p50/p99 ms | read ops/s | read p50/p99 ms |
|---|---|---|---|---|
| 0   | 12000 (100%) | 1.7 / 12.3  | —     | — |
| 4   | 11999 (100%) | 3.0 / 13.6  | 3920  | 0.8 / 4.5 |
| 16  | 7268 (61%)   | 4.7 / 36.0  | 7853  | 1.2 / 24.5 |
| 64  | 4203 (35%)   | 7.2 / 53.6  | 12541 | 2.9 / 43.6 |
| 128 | 2168 (18%)   | 14.9 / 89.4 | 14867 | 4.9 / 50.8 |

## Conclusions vs the premise

1. **The write path has no isolation from the read path.** The pinned 61%-of-ceiling write
   load survives 4 hot readers untouched (rate held; write p50 +76%, 1.7→3.0 ms — the early
   warning), then collapses once read pressure grows: **−39% at 16 readers, −65% at 64,
   −82% at 128**, with write p99 degrading 12 → 89 ms. Premise 1's optimistic reading
   ("readers don't hurt writers") is **refuted** for saturating catch-up read load.
2. **No load shedding, ever.** `write_bp = read_bp = 0` at every level — the server never
   returns 429/503; both classes just slow down together. Overload manifests purely as
   latency/throughput fair-sharing, which an operator cannot distinguish from "slow" without
   this measurement.
3. **The read path itself saturates sublinearly.** 32× more readers (4→128) yields only
   3.8× more catch-up reads/s while per-read p50 rises 6× — reads and writes converge on a
   shared bottleneck rather than reads scaling at writes' expense alone.

## Validity caveats (why this stays a local validation, not a result)

- **Readers are unpaced** — the sweep axis is "number of unbounded readers", i.e. *read-saturated
  coexistence*, not "N modest readers". A per-reader read-rate knob is required before this can
  make fair cross-implementation claims (a faster read path self-inflicts more interference).
- **Catch-up cost is non-stationary**: writers keep appending, so each successive replay is
  bigger (~200 backfill + up to ~4.8k appended events/stream by window end). read ops/s is
  therefore not a clean throughput metric across levels.
- **Single-node kind co-location**: client fleet, server and MinIO share one Docker VM, so part
  of the degradation may be node-level contention. The shape (monotone, early-latency-first) is
  trustworthy; the magnitudes need a remote run with separated node pools.
- `readers` counts completed full-stream replays; read **bytes/s** is not recorded yet.

## Before promoting to the full suite

- Add a paced-reader knob (`read_rate_per_reader`; keep rate 0 = hot loop as the adversarial mode).
- Record read bytes/s alongside read ops/s.
- Optional: a warmup/settle window in `ds-bench mixed` (rates currently include setup in elapsed,
  slightly understating the drive-window rate).

Companion: `results/mixed-delivery-local/FINDINGS.md` (the opposite interference direction).
Raw grid: `report.md` / `aggregate.{csv,json}` in this directory; suite: `suites/mixed-writes-local.json`.
