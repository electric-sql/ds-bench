# Write-Throughput Saturation Report — 2026-06-24

Single-node, best-case **write (append) throughput** for each streaming configuration,
measured with the saturation-finding suite (`scripts/bench`). Each (config, stream-count)
cell ramps client fleet pods up a ladder until throughput stops improving by ≥5% (the
plateau), then pins + re-confirms (3 reps). Raw data: `results/<suite>/`, machine-readable
summary: `results/combined.csv` / `results/combined-report.md`.

## Configuration
- **Server**: `c4d-standard-16-lssd` node, server cgroup-pinned to **4 CPU / 16 GiB**, data-dir on local NVMe, cold tier → in-cluster MinIO.
- **Clients**: 8× `n2d-standard-32`, `FLEET_CPU=2`, target **~1000 streams/pod**, `setup_concurrency=32`.
- **Method**: clean state per cell (server restart + data wipe between every rung), 15 s warm-up + 20 s measure, plateau threshold **5%**, `repeats=3` at the pinned point.
- **Configs**: `wal` (durable-streams, WAL, `--wal-shards 4`), `wal-tailcache` (same + 64 KiB resident tail-cache), `ursula` (single-node Raft, disk WAL), `s2` (S2-lite, object-store).
- **NOT** a multi-node/replicated comparison; ursula/s2 are single-node and are not server-CPU-instrumented.

## Headline — peak write throughput per configuration

| configuration | peak ops/s | at streams | saturation |
|---|---|---|---|
| **wal-tailcache** | **~684k** | 100 000 | plateau ✅ |
| **wal** | **~608k** (637k at 24 pods, n=1000) | 1 000 / 100 000 | plateau ✅ |
| **ursula** | **~10k** | 100 000 | plateau ✅ |
| **s2** | **~2k** | 100 | plateau ✅ (chokes ≥1 000) |

durable-streams (wal) sustains **~600–680k appends/s on 4 CPU** — roughly **60× ursula** and **300× s2**.

## Throughput matrix (ops/s; † = lower bound, ladder still climbing)

| streams | wal | wal-tailcache | ursula | s2 |
|---|---|---|---|---|
| 100 | 501k† | 502k† | 4k | 2k |
| 1 000 | 608k | 607k | 5k | choke |
| 10 000 | 476k | 530k | 6k | choke |
| 100 000 | 598k | 684k | 10k | choke |

## Findings

1. **durable-streams (wal) is the clear leader** — ~600–680k appends/s at 4 CPU, with clean
   plateaus at 1k/10k/100k streams. The earlier **100k creation-choke is resolved**: lowering
   stream-creation concurrency (`setup_concurrency` 256 → 32) let 100k complete at ~598k.

2. **Tail-cache shows no clear *write* benefit (as expected), but an unexplained high-cardinality
   delta.** wal and wal-tailcache are within ~1% at 100/1000 streams. At 10k/100k, tailcache reads
   ~11–14% higher (530k vs 476k; 684k vs 598k). The two variants ran **back-to-back on the same
   cluster**, so this isn't cluster variance — but tail-cache is a *read-path* knob and should not
   help pure appends. **Treat the tailcache "win" as unverified** (likely ordering/warm-up or
   measurement noise); a same-cell A/B repeat is needed before claiming a write benefit.

3. **ursula is ~60× slower** (~5–10k ops/s), throughput rising with cardinality (more streams →
   more parallelism it can absorb), peaking ~10k at 100k streams. Consistent with single-node Raft
   + disk WAL + S3 cold tier. Not server-CPU-instrumented, so saturation is plateau-only.

4. **s2 is creation-limited.** It measures ~2k ops/s at 100 streams, then **`creation_choke` at
   ≥1 000 streams** — even at `setup_concurrency=32`, S2-lite's object-store-backed stream creation
   can't keep up with mass creation. s2's usable write throughput at scale could not be measured;
   its bottleneck is stream *creation*, not append.

## Caveats / known limitations

- **n=100 is a lower bound** for wal/wal-tailcache (`501k†` / `502k†`) — the `[4,8,16,24,32]` ladder
  never plateaued (still climbing at 32 pods). The reported peaks come from higher-cardinality cells
  that *did* plateau, so the headline is unaffected; re-run n=100 with higher rungs to pin it.
- **s2 ≥1 000 streams** has no throughput number (creation-choked) — a documented limit, not a ceiling.
- Single-node, best-case; not a 3-voter quorum. ursula/s2 server CPU/RSS not instrumented.
- Each number is the median of 3 reps at the pinned pod count; pinned pods are the saturation knee,
  not necessarily the single highest rung (e.g. wal n=1000 pins 16 pods/608k though 24 pods hit 637k).

## Benchmark bugs found & fixed during this campaign

- **`_record` dropped whole cells** on a malformed/empty p99 (crash in `float()`), silently losing
  plateau cells — now tolerant (bad value → `None`/`0`), so a cell is always recorded.
- **`reset_state` creation-choke** — between-rung restarts only waited for TCP readiness; added an
  HTTP-readiness gate so the fleet never races a not-yet-serving server.
- **`cap_ladder`** — low-cardinality cells no longer over-provision (pods capped at stream count).
- **`setup_concurrency`** made configurable (default 32) to decouple stream-creation pressure from
  pod count (the 100k-choke fix).
- **Test hygiene** — `bench_test` no longer writes/rm's a real suite's state file (had orphaned a
  live cluster); `lib-saturate_test` is self-contained (was passing for the wrong reason).
- **Reliability** — `PULL_POLICY=IfNotPresent` for per-rung restarts (node-cached image), and an
  independent hard-deadline teardown watchdog so clusters can never bill indefinitely.

## Reproduce
    nohup scripts/teardown-watchdog.sh > .bench-state/watchdog.log 2>&1 & disown
    nohup scripts/run-all.sh           > .bench-state/run-all.log  2>&1 & disown
See `docs/RUNBOOK.md`.
