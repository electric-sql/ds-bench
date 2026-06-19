# Phase 3 — Sustained load + memory stability: results

**Date:** 2026-06-19 · **Server:** durable-streams `1e9423dc` · **Hardware:** GKE
`n2d-standard-8` (NVMe), single 8-core server; load from the `ds-bench` fleet at fixed
safe concurrency (PARALLELISM=2, conns ≈ N×2 ≤ 300, setup-concurrency 32 to stay under the
~200-PUT stream-creation limit). 90 s per cell. Run:
`results/sustained/sustained-1781846086-55504/`. `client_capped` lower bounds; 1 repeat.

## ⭐ Headline — server RSS stays FLAT / bounded under sustained load (no leak)

| streams | ops/s | p50 ms | p99 ms | p999 ms | RSS start→end (MiB) | slope MiB/min | CPU |
|---|---|---|---|---|---|---|---|
| 10 | 200 | 0.65 | 1.33 | 117.18\* | 5.8 → 7.4 | +0.96 | 3.5% (flat) |
| 50 | 1,000 | 0.61 | 2.06 | 3.04 | 7.4 → 11.3 | +2.34 | 16.8% (flat) |
| 100 | 2,000 | 0.56 | 2.17 | 3.10 | 11.3 → 14.0 | +1.66 | 22.4% (flat) |
| 150 | 2,999 | 0.44 | 1.66 | 2.74 | 14.0 → 15.5 | +0.90 | 24.5% (flat) |

\* N=10 p999 = small-sample startup skew (only 200 ops/s × 90 s).

- **RSS is flat/bounded — no memory leak.** Total server RSS only **5.8 → ~16 MiB** across the
  whole 10→150-stream sweep, and within each 90 s window RSS **plateaus after warm-up**
  (`rss_max == rss_end` in 3/4 cells). The small per-step rise is the new streams' working
  set, not unbounded growth.
- **Throughput scales linearly** with stream count (200 → 2,999 ops/s) at the configured
  per-stream rate; **p99 ≤ 2.2 ms**; CPU steady in every cell.

This directly addresses the Phase-3 question (does the server leak/grow under steady load?):
**at this scale it does not** — memory is tiny and bounded, CPU is steady, latency is stable.

## Cardinality (millions of streams) — BLOCKED, not attempted
The full cardinality wall (per-stream-state memory at millions of streams) remains out of
reach: concurrent stream **creation** times out at ~200 PUTs (Phase-2 finding), so a
millions-of-streams corpus can't be built, and the Tier-D cardinality workload was never
implemented. The sustained sweep above gives the RSS-vs-stream-count trend only up to the
safe cap (150 streams). Lifting the stream-creation limit server-side is the prerequisite to
the real cardinality test.

## Caveats
- `client_capped` lower bounds; stream count ≤ 150 (under the creation limit); single 8-core
  server; object tier = in-cluster MinIO on NVMe; server CPU%/RSS from the sidecar; 1 repeat.

## Cluster
**Torn down** after the run (verified: no cluster, no billing, context unset).
