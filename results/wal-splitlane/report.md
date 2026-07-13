# wal-splitlane — write-throughput report

## Throughput at saturation (ops/s)

| streams | ref-3s | ckpt-off | nofsync |
|---|---|---|---|
| 10000 | 293k† | 309k† | 270k† |
| 100000 | 272k | 306k | 264k |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | ref-3s | ckpt-off | nofsync |
|---|---|---|---|
| 10000 | 229 / 176 | 291 / 204 | 233 / 190 |
| 100000 | 657 / 580 | 689 / 598 | 629 / 584 |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Latency (ms, p50 / p99)

| streams | ref-3s @≤80% load | ref-3s @saturation | ckpt-off @≤80% load | ckpt-off @saturation | nofsync @≤80% load | nofsync @saturation |
|---|---|---|---|---|---|---|
| 10000 | 3.1 / 16.4 (293k @4p) | — | 3.1 / 7.9 (309k @4p) | — | 3.1 / 8.8 (261k @4p) | — |
| 100000 | 1.5 / 6.7 (269k @2p) | 1.5 / 6.5 | 1.5 / 6.4 (296k @2p) | 1.5 / 6.6 | 1.4 / 7.4 (260k @2p) | 1.4 / 7.5 |

_@≤80% load = the largest ladder rung at ≤80% of peak throughput — the server's service latency with headroom. @saturation = the pinned plateau rung, where a closed-loop fleet measures its own queueing (≈ in-flight ÷ ceiling by Little's law), NOT the server's per-request cost. Compare against the unloaded single-request baseline (~1 ms for wal) before reading anything into large saturation values._

## Saturation walks (pods → ops/s, p50 ms)

- **ckpt-off 10000**: 4:309k@3.1ms → 8:305k@6.5ms  (pinned 8, ladder_exhausted)
- **nofsync 10000**: 4:261k@3.1ms → 8:270k@6.6ms  (pinned 8, ladder_exhausted)
- **ref-3s 10000**: 4:293k@3.1ms → 8:286k@6.5ms  (pinned 8, ladder_exhausted)
- **ckpt-off 100000**: 2:296k@1.5ms → 4:298k@3.1ms → 8:294k@6.5ms  (pinned 2, plateau)
- **nofsync 100000**: 2:260k@1.4ms → 4:259k@3.2ms → 8:251k@6.7ms  (pinned 2, plateau)
- **ref-3s 100000**: 2:269k@1.5ms → 4:256k@3.3ms → 8:271k@6.7ms  (pinned 2, plateau)

## Findings

**The write cardinality cliff is eliminated.** ref-3s (syncfs checkpoint @3s, full durability) holds 286k→272k ops/s from 10k→100k streams (−5%) on the split-lane layout — vs 10.4k @100k where this investigation started (26×).

Decomposition (with wal-decomp-lane0):
- **Storage layout is the #1 lever.** Streams on the PD boot disk → 10.4k; everything on one shared NVMe lane → 46k; streams on their own lane + WAL shards on dedicated lanes → 272k. The old "~1000 fdatasync/s device ceiling" was commit-vs-checkpoint device contention.
- **Commit fdatasync on dedicated lanes is free**: ckpt-off (306k) ≥ nofsync (264k) — group-commit amortizes better under fsync backpressure than the free-running no-fsync path.
- **Checkpoint @3s costs ~7–11%** on this layout (306k → 286k/272k). The per-shard size-trigger knob (perf/wal-checkpoint-sizetrigger) can reclaim most of it by checkpointing on a retained-WAL budget instead of a timer.
- Remaining gap to memory mode (512k) is ~1.9× = WAL machinery (staging/double-write), not fsync — future work: io_uring WAL writer seam, batched mark-written.

Production recipe: multi-device NVMe instance, streams dir on its own device, one WAL shard per remaining device, `--wal-checkpoint-syncfs on`.

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
