# Local reproduction of the cardinality cliff (kind, 2026-07-08)

**Purpose:** prove the remote cardinality cliff reproduces on a laptop so
server-side work can iterate locally (minutes, free) instead of on GKE
(hours, billed). It does. The authoritative how-to-iterate guide lives with the
server code: `packages/durable-streams-rust/CARDINALITY_CLIFF_REPRO.md` in the
electric repo.

## Result: the cliff reproduces, earlier and steeper than remote

Local kind, server pinned 2 vCPU (`--wal-shards 2 --worker-threads 2` /
`--durability memory --worker-threads 2`), pool client 64 conns/pod, ladder
1→2→4 pods. Top-rung throughput (fixed 4-pod offered load) and knee p50,
normalized to n=1000:

| streams | wal thr | wal rel | wal knee p50 | memory thr | memory rel | memory knee p50 |
|---|---|---|---|---|---|---|
| 1k | 55.4k | 100% | 2.9 ms | 112.5k | 100% | 0.5 ms |
| 10k | 48.2k | 87% | 3.0 ms | 63.7k | 57% | 0.6 ms |
| 50k | 27.8k | 50% | 5.0 ms | 22.7k | 20% | 3.9 ms |
| 100k† | 10.4k | 19% | 6.1 ms | 17.7k | 16% | 5.0 ms |
| 200k† | 6.7k | 12% | 8.6 ms | — | — | — |

† collected before the suite was trimmed; kept for context. **The fast loop is
[1k, 10k, 50k]** (~15 min for both configs) — the cliff is unambiguous by 50k;
bigger counts only slow iteration.

Remote (corrected campaign, `write-wal-vs-mem-cpu4/FINDINGS.md`): wal −33%,
memory −28–39% over 100k→500k. Locally the cliff starts at ~10k instead of
~100k+ — consistent with the mechanism (per-stream working-set / page-cache /
registry physics vs a much smaller cache envelope: 2 vCPU, 8 GB Docker VM,
overlayfs). The knee p50 rising with cardinality (2.9→8.6 ms wal, 0.5→5 ms
memory at ≤80% load) is the signature that per-REQUEST cost grows — this is not
queueing (latency is quoted below the knee) and not fsync (memory mode has no
WAL and cliffs at least as hard).

## How to iterate (summary — full guide in the server repo doc)

```bash
# once: build server+client images from the local checkout and load into kind
BUILD_NODE=0 DS_TARGET=local bash scripts/build-images.sh
# each iteration: rebuild after a server change, wipe, re-run, compare
rm -rf results/write-cliff-local && DS_TARGET=local scripts/bench suites/write-cliff-local.json run
python3 scripts/compare-cliff.py
```

`scripts/compare-cliff.py` prints the normalized local curves next to the
remote reference. Judge a server change by the SHAPE (rel% at 10k/50k vs
baseline), not absolute ops/s.

## CPU-scaling probe (`write-cliff-local-cpu4`): also reproduces

Same client model, server at 4 vCPU / 4 shards over [10k, 50k], vs this suite's
2-vCPU / 2-shard wal cells (top rung = 4 pods × 64 conns):

| streams | wal 2 vCPU/2 shards | wal 4 vCPU/4 shards |
|---|---|---|
| 10k | 48.2k | 43.8k |
| 50k | 27.8k | 31.8k |

Doubling CPU+shards moves throughput −9%/+14% — flat within noise, matching the
remote pattern (47k @4 vCPU vs 43k @8 vCPU). The wal commit-path investigation
can iterate locally too.
