# mixed-writes-local — do catch-up readers hurt a pinned write load? (local kind validation)

**Setup (v2, 2026-07-02).** durable `wal` built from `electric-ds-rust`
`bench/mixed-interference-validation` (off `perf/combined-t1a-t1c-t2a`), local kind
(server 2 CPU / 2 Gi), 50 shared streams, 1 writer/stream pinned at 355 appends/s each
= **17.75k ops/s offered ≈ 60% of the measured local ceiling** (29.7k ops/s from
`mixed-cal-local`, p50 1.5 ms / p99 6.4 ms). Readers are **paced at 1 replay/s each**
(`read_rate: 1`), so the sweep axis is a bounded offered read load; all three classes
now share one barrier→deadline window and rates divide by it. 20 s windows, 256 B
payloads, fresh server per level.

| readers (≈replays/s offered) | write ops/s | write p50/p99 ms | read replays/s | read MiB/s | read p50/p99 ms |
|---|---|---|---|---|---|
| 0   | 17303 | 1.2 / 9.8  | —   | —     | — |
| 4   | 17755 | 1.0 / 5.7  | 4   | 3.8   | 1.7 / 10.5 |
| 16  | 17756 | 0.9 / 5.3  | 17  | 15.4  | 3.9 / 17.1 |
| 64  | 17756 | 1.0 / 6.5  | 67  | 61.5  | 5.5 / 65.5 |
| 128 | 17750 | 1.1 / 52.9 | 134 | 123.0 | 4.9 / 50.9 |

## Conclusions vs the premise (v2 — bounded read load)

1. **Write throughput is unharmed by a bounded catch-up read load.** The pinned 60%-of-
   ceiling write rate is delivered to within noise at every level, up to 128 readers
   pulling **123 MiB/s** of replay bandwidth off the same 2-CPU server. Every reader also
   achieved its offered pace (134 ≈ 128 replays/s).
2. **Interference shows up in the tails, and only past ~60 MiB/s of read bandwidth.**
   Write p99 sits at 5–10 ms through 64 readers, then jumps to **53 ms at 128** while
   write p50 stays ~1 ms — tail coupling, not capacity loss. Read p99 degrades in step
   (65 ms at 64 readers, when each replay is already ~1 MB).
3. **Still no load shedding** — zero 429/503 anywhere; the coupling is silent.

## The v1 contrast: unpaced readers (adversarial reference, 2026-07-02 morning run)

The first validation ran the same sweep with **unpaced hot-loop readers** (and writers
pinned at 12k = 61% of the then-19.6k ceiling, older server build, rates over full
elapsed): write throughput collapsed −39% at 16 readers, −65% at 64, −82% at 128. That
mode measures *read-saturated coexistence* — worst-case, and the reason the paced knob
exists. Keep `read_rate: 0` as the adversarial variant; with pacing the same suite
measures realistic bounded interference. The two together bracket the behaviour:
**bounded read load costs ~nothing in write throughput; unbounded read load fair-shares
everything down.**

## Validity caveats

- Single-node kind co-location (client fleet + server + MinIO on one Docker VM): the
  128-reader p99 spike may be partly node-level; magnitudes need a remote run with
  separate node pools.
- Replay bodies grow during the window (~200 backfill + up to ~7k appended events by the
  end), so per-replay cost rises within a run — read MiB/s is the steadier axis.

## Status for promotion

The v1 blockers are fixed in `ds-bench mixed`: paced readers (`--read-rate`), read
bytes/s recorded, barrier-aligned drive window, delivery counters split (data vs
control frames). Remaining before adding to the full remote suite: pick per-system
%-of-ceiling anchors from the `run-*` saturation results, and decide the paced level
grid (readers × read_rate) per cardinality.

Companion: `results/mixed-delivery-local/FINDINGS.md`. Raw grid: `report.md` /
`aggregate.{csv,json}` here; suite: `suites/mixed-writes-local.json`.
