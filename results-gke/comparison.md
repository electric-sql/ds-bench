# Phase 2b.2 — single-node head-to-head (GKE, MinIO-on-NVMe object tier)

All systems run at **a single node** with matched durability (group-committed writes + an S3-compatible cold tier on the SAME in-cluster MinIO, which sits on the server node's local NVMe). Latencies are the EXACT cross-node HDR merge of every client-fleet pod; throughput sums each pod's headline. DS-node is **SKIPPED** (Node server is a library — no entrypoint/env-config and no S3 cold tier; see `gke/ds-node-SKIPPED.md`).

## multi-stream — write throughput

| metric | DS-rust | ursula | S2 Lite |
|---|---|---|---|
| aggregate writes/s | 78,490 | 7,611 | 15,323 |
| p50/p90/p99/p999 ms | 9.62 / 17.10 / 23.81 / 30.02 | 92.35 / 180.99 / 309.25 / 403.97 | 51.26 / 60.13 / 72.38 / 235.65 |
| merged samples | 2,355,695 | 229,970 | 460,482 |

## fan-out — SSE end-to-end latency

_ops/s is N/A for fan-out (the headline is the merged delivery latency); events/s shown for context._

| metric | DS-rust | ursula | S2 Lite |
|---|---|---|---|
| fan-out p50/p90/p99/p999 ms | 15.10 / 32.58 / 47.42 / 82.94 | 79.61 / 95.10 / 916.48 / 1208.32 | 50.81 / 59.65 / 63.17 / 65.34 |
| events/s (Σpods) | 119,984 | 44,791 | 84,920 |
| events received | 3,599,529 | 1,343,736 | 2,547,596 |

## catch-up — replay throughput

_S2 Lite excluded from catch-up (paginated JSON-enveloped read, not comparable)._

| metric | DS-rust | ursula | S2 Lite |
|---|---|---|---|
| aggregate MB/s (Σpods) | 786.43 | 988.01 | - |
| bytes received | 6,400,000 | 47,897,600 | - |
| p50/p90/p99/p999 ms | 6.48 / 7.38 / 7.48 / 7.48 | 37.09 / 57.15 / 59.23 / 59.26 | - |

## mixed — write / fan-out / read (per class)

_S2 Lite excluded from mixed._

| class | metric | DS-rust | ursula |
|---|---|---|---|
| **write** | p50/p90/p99/p999 ms | 1.11 / 1.83 / 5.19 / 8.12 | 20.64 / 28.08 / 37.82 / 55.68 |
| **fanout** | p50/p90/p99/p999 ms | 0.62 / 1.22 / 3.34 / 6.39 | 20.99 / 28.75 / 305.15 / 520.96 |
| **read** | p50/p90/p99/p999 ms | 1.16 / 2.73 / 6.05 / 10.21 | 15.21 / 27.10 / 38.21 / 63.65 |

## saturation curve — DS-rust multi-stream vs client-fleet pods

_The one sweep run (full payload×subscriber×system cartesian deferred for cost)._

| client pods | aggregate writes/s | p99 ms | p999 ms | merged samples |
|---|---|---|---|---|
| 2 | 84,264 | 15.29 | 19.45 | 2,528,750 |
| 4 | 181,029 | 15.38 | 22.69 | 5,433,141 |
| 8 | 200,193 | 20.00 | 26.21 | 6,008,510 |

_Throughput is **rising** from 2→8 pods (84,264 → 200,193 writes/s)._

## Disclosures (fairness / honesty)

- **Object tier = in-cluster MinIO on local NVMe** — near-best-case for the cold tier (low latency, no cross-AZ hop); NOT representative of real cloud S3. It is identical for every system, so comparisons are fair, but absolute numbers would be lower against cloud S3.
- **Matched single-node durability + group-commit symmetry** — every system group-commits writes and offloads to the same S3-compatible tier; no system is given a weaker-durability fast path.
- **S2 is a different substrate** and is **excluded from catch-up and mixed** (its paginated JSON-enveloped read path is not comparable); it runs multi-stream + fan-out only.
- **ursula is single-node only.** Multi-node (1/3/5) is deferred to Phase 3 (durable-streams does not yet support multi-node), so this is a clean apples-to-apples single-node head-to-head with no multi-node honesty caveat.
- **DS-node SKIPPED** — the Node/TS durable-streams server is a reference library (no standalone entrypoint, no env-based config, no S3 cold tier), so it cannot be made durability-matched. See `gke/ds-node-SKIPPED.md`.
- **Deferred sweeps** — only one saturation sweep (DS-rust multi-stream, client pods 2→4→8) was run. The full payload×subscriber×system cartesian and ursula multi-node scale-out are deferred for cost.
