# Phase 2 — Multi-stream scale-out: results

**Date:** 2026-06-19 · **Server:** durable-streams `1e9423dc` · **Hardware:** GKE
`n2d-standard-8` (NVMe), single 8-core server; load from the `ds-bench` fleet at fixed
safe concurrency (PARALLELISM=2, capped ≤ ~512 conns to stay under the Phase-1 hang limit).
Run: `results/scaleout/scaleout-slow-1781844201-51063/`. All numbers are `client_capped`
lower bounds; 1 repeat.

## Multi-stream write throughput vs stream count (8-core server)

| streams | writes/s | verdict |
|---|---|---|
| 10 | 26,858 | client_capped |
| 50 | **35,106** | client_capped |
| 100 | — | **FAILED** (stream-creation timeout) |
| 200 | — | **FAILED** (stream-creation timeout) |

Writes scale modestly 10→50 streams (27k→35k/s), then **fail at 100+ streams** — see the
new finding below.

## Multi-stream fan-out (M streams × S subscribers)

| M | S | events/s | p50 ms | p99 ms | p999 ms |
|---|---|---|---|---|---|
| 10 | 10 | 37,020 | 1.38 | 3.79 | 4.35 |
| 10 | 20 | 59,529 | 4.67 | 15.73 | 17.98 |
| 20 | 10 | **66,898** | 4.09 | 16.62 | 27.84 |

Multi-stream fan-out delivers ~37k–67k events/s with p99 ~4–17 ms across these small
M×S points — clean low-latency delivery, scaling with total subscriber count.

## ⚠️ NEW FINDING — bulk stream creation times out at ~200+ concurrent PUTs
At 100 and 200 concurrent streams, **`PUT /v1/stream` (stream creation) timed out** — a
**new, lower bottleneck** than the ~1024-connection hang from Phase 1. Notably the server
did **not hang** this time (pod stayed `2/2 Running`, `GET /` returned 404 throughout) — so
this is a distinct issue: **concurrent stream *creation* doesn't scale past ~200**, separate
from the steady-state connection-concurrency hang. Both bound how far the multi-stream
scale-out can be pushed and are worth investigating server-side.

(The tolerant fleet/coordinator waits added this session caught these failures and kept the
matrix running instead of aborting.)

## Caveats
- All cells `client_capped` (lower bounds) — couldn't saturate the server within the safe
  concurrency cap.
- Single 8-core server; object tier = in-cluster MinIO on NVMe; server CPU% from the sidecar;
  1 repeat (no median/cv).

## Cluster
**Torn down** after the run (verified: no cluster, no billing, context unset).
