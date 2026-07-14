# ds-bench canonical campaign — 2026-07-14 (post-cardinality-cliff build)

First run of the canonical suite set, on the electric#4697 merged-state build
(syncfs checkpoints, per-shard triggers, stream lanes; see WAL_TUNING.md).
Provenance in `PROVENANCE.md`; per-suite grids in each subdirectory.

## 1. Write saturation (`canonical-write`, `canonical-write-ursula`)

Peak append/s at saturation (256 B payloads):

| streams | wal-ideal | memory | ursula-mem | ursula-disk |
|---|---|---|---|---|
| 100  | — | — | 52.0k | 4.5k |
| 1k   | — | — | 54.7k | 7.4k |
| 10k  | 417.0k | 680.4k | 49.0k | 8.3k |
| 100k | **382.3k** | **631.5k** | — | — |

- All four durable-streams cells are true plateaus (pinned rungs). **No
  cardinality cliff: −8% (wal) / −7% (memory) from 10k→100k.** Regression gates
  (wal@100k > 250k, memory@100k > 400k) passed with wide margin.
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
- **Delivery under write load (2000 SSE subscribers):**

| writes/s | wal del/s (p99 ms) | memory del/s (p99 ms) |
|---|---|---|
| 4k  | 3.3k (138) | 3.3k (151) |
| 16k | 15.9k (54) | 13.3k (5) |
| 40k | 33.3k (86) | 33.2k (2) |
| 66k | 54.9k (107) | 65.7k (8) |
| max | 63.8k @ 85k writes (106) | **126.7k @ 127k writes (45)** |

  **The 2026-07-02 memory-mode delivery collapse is GONE** on this build:
  memory delivery tracks writes 1:1 all the way to 127k/s. wal delivery keeps
  pace to ~40k writes/s and caps at ~64k del/s at full write saturation.

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
