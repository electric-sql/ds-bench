# DS-rust — raw single-node benchmark results (GKE, MinIO-on-NVMe object tier)

These are **raw DS-rust (durable-streams Rust server) numbers** from a single-node GKE deployment. They are not a cross-system comparison — see `results-gke/comparison.md` for the head-to-head table.

## multi-stream — write throughput

| metric | value |
|---|---|
| aggregate writes/s | 78,490 |
| p50/p90/p99/p999 ms | 9.62 / 17.10 / 23.81 / 30.02 |
| merged samples | 2,355,695 |

## fan-out — SSE end-to-end latency

_ops/s is N/A for fan-out (the headline is the merged delivery latency); events/s shown for context._

| metric | value |
|---|---|
| events/s (Σpods) | 119,984 |
| fan-out p50/p90/p99/p999 ms | 15.10 / 32.58 / 47.42 / 82.94 |
| events received | 3,599,529 |

## catch-up — replay throughput

| metric | value |
|---|---|
| aggregate MB/s (Σpods) | 786.43 |
| bytes received | 6,400,000 |
| p50/p99 ms | 6.479 / 7.483 |

## mixed — per-class latency (write / fan-out / read)

| class | p50/p90/p99/p999 ms |
|---|---|
| write | 1.11 / 1.83 / 5.19 / 8.12 |
| fanout | 0.62 / 1.22 / 3.34 / 6.39 |
| read | 1.16 / 2.73 / 6.05 / 10.21 |

## saturation curve — DS-rust multi-stream vs client-fleet pods

_Sweep: client-fleet pods 2 → 4 → 8, all other parameters held constant._

| client pods | aggregate writes/s | p99 ms | p999 ms | merged samples |
|---|---|---|---|---|
| 2 | 84,264 | 15.29 | 19.45 | 2,528,750 |
| 4 | 181,029 | 15.38 | 22.69 | 5,433,141 |
| 8 | 200,193 | 20.00 | 26.21 | 6,008,510 |

_Throughput is **rising** from 2→8 pods (84,264 → 200,193 writes/s)._

## Disclosures

- **Single-node deployment** — DS-rust server runs as a single pod on an `n2d-standard-8` GKE node (8 vCPU, 32 GB RAM). These numbers reflect single-node capacity only; multi-node scale-out is deferred to Phase 3.
- **Object tier = in-cluster MinIO on local NVMe** — near-best-case for the cold tier (low latency, no cross-AZ hop); NOT representative of real cloud S3. Absolute numbers would be lower against a remote S3 endpoint.
- **Group-commit durability** — writes are group-committed before acknowledgement and offloaded to the S3-compatible tier; this is the same durability posture used in the cross-system comparison.
- **These are RAW DS-rust numbers** — not a cross-system claim. For head-to-head comparisons with ursula and S2 Lite, see `results-gke/comparison.md`.
- **Latencies are HDR-merged** across all client-fleet pods; throughput sums each pod's headline figure.
