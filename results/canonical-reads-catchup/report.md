# canonical-reads-catchup — read-scalability report

Each cell: aggregate read throughput (MiB/s) @ p99 latency (ms). ‡ = backpressure (503/429) observed at this load.

## wal — throughput @ p99 over stream_count × connections

| streams | 8 | 32 | 128 | 512 |
|---|---|---|---|---|
| 10 | 2273MiB/s@62ms | 2393MiB/s@249ms | 2368MiB/s@1478ms | 2727MiB/s@5071ms |
| 100 | 2276MiB/s@62ms | 2386MiB/s@249ms | 2354MiB/s@1376ms | 2739MiB/s@4645ms |

Peak read throughput per cardinality:
- streams=10: 2727 MiB/s at 512 connections
- streams=100: 2739 MiB/s at 512 connections

## ursula — throughput @ p99 over stream_count × connections

| streams | 8 | 32 | 128 | 512 |
|---|---|---|---|---|
| 10 | 2353MiB/s@66ms | 2374MiB/s@485ms | 2469MiB/s@1763ms | 2902MiB/s@12100ms |
| 100 | ERR(0) | ERR(0) | ERR(0) | ERR(0) |

Peak read throughput per cardinality:
- streams=10: 2902 MiB/s at 512 connections
- streams=100: 0 MiB/s at 8 connections

## Findings

_TODO: written by hand on top of the generated data._
