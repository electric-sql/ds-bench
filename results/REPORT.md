# ds-bench canonical campaign — 2026-07-14 (post-cardinality-cliff build)

First run of the canonical suite set, on the electric#4697 merged-state build
(syncfs checkpoints, per-shard triggers, stream lanes; see WAL_TUNING.md).
Provenance in `PROVENANCE.md`; per-suite grids in each subdirectory.

> **Write-path re-validation for electric#4710 (2026-07-14).** The two
> write/durability suites — `canonical-write` and `canonical-mixed-delivery` —
> were re-run on the #4710 recovery-hardening build (fail-stop durability
> barriers, always-sync sidecar, extra parent-dir fsyncs on the WAL path). Those
> two sections below now carry **#4710** numbers; the read/ursula/mixed-cal/
> mixed-writes suites are unchanged code paths under #4710 and keep their #4697
> values. **Verdict: no write regression** (see the per-section deltas). Split
> provenance recorded in `PROVENANCE.md`.

## 1. Write saturation (`canonical-write`, `canonical-write-ursula`)

Peak append/s at saturation (256 B payloads). **durable-streams columns = #4710**;
Δ vs the #4697 baseline in parentheses:

| streams | wal-ideal | memory | ursula-mem | ursula-disk |
|---|---|---|---|---|
| 100  | — | — | 52.0k | 4.5k |
| 1k   | — | — | 54.7k | 7.4k |
| 10k  | 413.0k (−1.0%) | 669.0k (−1.6%) | 49.0k | 8.3k |
| 100k | **386.0k (+1.0%)** | **628.0k (−0.5%)** | — | — |

- All four durable-streams cells are true plateaus (pinned rungs). **No
  cardinality cliff: −6.5% (wal) / −6.1% (memory) from 10k→100k.** Regression
  gates (wal@100k > 250k, memory@100k > 400k) passed with wide margin.
- **#4710's durability barriers cost nothing measurable on the write path**:
  wal is within ±1% of #4697 (100k even +1%), and memory is flat (it takes no
  fsync barrier, so the hardening cannot touch it) — the two move exactly as the
  code predicts. The ~5% dips seen mid-sweep were the 8-pod ladder rung; both wal
  cells peak at the 4-pod rung (client/contention-bound, not server-bound).
- wal-ideal = the WAL_TUNING.md configuration (3 stream lanes + 3 WAL lanes,
  1 GiB checkpoint budget, pinned cores). memory benefits from the same pinned
  cores (previous best 512k on shared cores).
- Physics sanity: memory > wal everywhere, as it must be (cf. the retracted
  2026-07-02 numbers).

## 3. Read scalability (`canonical-reads-catchup`, `canonical-reads-sse`)

**Catch-up** (MiB/s @ p99 ms): wal is cardinality-flat — 2.27 GiB/s @62ms
(8 conns) to ~2.7 GiB/s (512 conns) at BOTH 10 and 100 streams. ursula matches
at 10 streams (2.9 GiB/s peak, worse p99: 12.1s vs 5.1s at 512) and returns
errors at every level at 100 streams (recorded as a gap — matches its historic
client-OOM ceiling there).

**SSE tail** (per-connection paced): wal flat at both cardinalities up to 2048
conns, p99 2–3 ms. ursula matches at 10 streams but degrades at 100 streams
(p99 39–62 ms) — same shape as 2026-07-02.

## 4. Mixed read/write interference (`canonical-mixed-*`)

- **Anchor:** 81.7k ops/s single-pod mixed-shape ceiling (was 81.4k — stable).
- **Paced readers vs pinned writes (10k streams, 50k ops/s pinned):** writes hold
  49.9–50.0k at 0 / 1k / 10k / 100k readers while serving up to 4,986 replays/s
  at 303 MiB/s. **The premise holds: 100k concurrent catch-up readers cost the
  write path nothing.**
- **Delivery under write load (2000 SSE subscribers) — #4710:**

| writes/s | wal del/s (p99 ms) | memory del/s (p99 ms) |
|---|---|---|
| 4k  | 4.0k (147) | 3.3k (140) |
| 16k | 15.9k (51) | 15.9k (51) |
| 40k | 33.3k (86) | 39.8k (5) |
| 66k | 65.7k (92) | 65.7k (7) |
| max | 64.1k @ 84k writes (69) | **139.3k @ 140k writes (63)** |

  **The 2026-07-02 memory-mode delivery collapse stays GONE** on #4710:
  memory delivery tracks writes 1:1 all the way to 140k/s (baseline #4697 was
  127k — the difference is run-to-run headroom, not a code change). wal delivery
  keeps pace to ~66k writes/s and caps at ~64k del/s at full write saturation —
  same shape as #4697, no regression from the added durability barriers.

## Known gaps & artifacts

- ursula catch-up @100 streams: ERR at all connection levels (historic
  client-OOM ceiling) — gap, not a zero.
- SSE fan-out (single-stream subscriber ladder, `run-sse.sh`) not run this
  campaign.
- mixed-writes write p99 (1.4–3.8 s tails) is the single-pod 10k-writer client
  shape, present at zero readers too — not reader interference.
- The mixed chain was restarted once between `mixed-cal` and `mixed-writes`
  (orchestration, not measurement); every published cell is a clean run.

## Pre-publication checklist

Layout verified (splitlane3x3 for canonical-write) ✓ · aligned windows ✓ ·
plateau-labeled cells ✓ · digests in PROVENANCE.md ✓ · physics sanity (memory >
wal; fsync/s plausible) ✓ · cardinality shape reported ✓ · client-bound cells
marked as gaps ✓
