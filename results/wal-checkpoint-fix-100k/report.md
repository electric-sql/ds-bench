# wal-checkpoint-fix-100k — write-throughput report

## Throughput at saturation (ops/s)

| streams | syncfs | both |
|---|---|---|
| 100000 | 14k† | 12k† |

† = not saturated (ladder exhausted) — treat as a lower bound.

## Pod memory at saturation — peak / p50 (MiB)

| streams | syncfs | both |
|---|---|---|
| 100000 | 549 | — |

_Pod working set = cgroup `memory.current − inactive_file` (anon + active page cache), sampled each second at the pinned rung. **peak** = high-water (catches bursts like an in-RAM Raft log filling); **p50** = median (what the server steadily holds resident). peak ≈ p50 ⇒ steadily resident; peak ≫ p50 ⇒ transient spikes._

## Latency (ms, p50 / p99)

| streams | syncfs @≤80% load | syncfs @saturation | both @≤80% load | both @saturation |
|---|---|---|---|---|
| 100000 | 1.7 / 1461.2 (11k @2p) | — | 3.7 / 1650.7 (8k @4p) | — |

_@≤80% load = the largest ladder rung at ≤80% of peak throughput — the server's service latency with headroom. @saturation = the pinned plateau rung, where a closed-loop fleet measures its own queueing (≈ in-flight ÷ ceiling by Little's law), NOT the server's per-request cost. Compare against the unloaded single-request baseline (~1 ms for wal) before reading anything into large saturation values._

## Saturation walks (pods → ops/s, p50 ms)

- **both 100000**: 2:12k@1.6ms → 4:8k@3.7ms  (pinned 4, ladder_exhausted)
- **syncfs 100000**: 2:11k@1.7ms → 4:14k@3.7ms  (pinned 4, ladder_exhausted)

## Findings

Reference (aborted wal-checkpoint-fix-ab run, same cluster/image family): **baseline@100k = 10.4k** ops/s at p2, degrading to 9.0k (p4) / 7.3k (p8) — throughput *falls* as load rises because the synchronized O(N)-fdatasync checkpoint wave stalls commits.

- **syncfs wins**: 13.6k at p4 (+51% vs baseline's 9.0k at matched p4), and still climbing when the ladder ended — a lower bound. Shape flips from degrades-with-load to scales-with-load.
- **stagger adds nothing**: `both` ≤ syncfs alone. Consistent with mechanism: one shard's checkpoint pass (~13s at 100k) exceeds the 3s interval, so staggering cannot keep pace. Stagger prototype dropped from the branch.
- **Cliff softened, not eliminated**: ~110k @10k streams vs ~14k @100k, and p99 @≤80% load is still ~1.5s (checkpoint stalls remain). The residual cost is the O(N_touched) random writeback of per-stream files itself, which no barrier strategy fixes — that is the log-structured-store argument (issue #4695); cold-tier-as-durable is #4696.

Merged: `--wal-checkpoint-syncfs` (branch perf/wal-checkpoint-syncfs → campaign branch), flag-gated, default off.

## Caveats

_Single-node best-case; not 3-node Raft. Throughput is a saturation ceiling per the ladder._
