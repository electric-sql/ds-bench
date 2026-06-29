# reads-catchup — read-scalability report

Each cell: aggregate read throughput (MiB/s) @ p99 latency (ms). ‡ = backpressure (503/429) observed at this load.

## wal — throughput @ p99 over stream_count × connections

| streams | 8 | 32 | 128 | 512 |
|---|---|---|---|---|
| 10 | 2246MiB/s@77ms | 2363MiB/s@293ms | ERR(0) | ERR(0) |
| 100 | 2077MiB/s@85ms | 2374MiB/s@261ms | ERR(0) | ERR(0) |

Peak read throughput per cardinality:
- streams=10: 2363 MiB/s at 32 connections
- streams=100: 2374 MiB/s at 32 connections

## ursula — throughput @ p99 over stream_count × connections

| streams | 8 | 32 | 128 | 512 |
|---|---|---|---|---|
| 10 | 2350MiB/s@71ms | 2379MiB/s@546ms | ERR(0) | ERR(0) |
| 100 | ERR(0) | ERR(0) | ERR(0) | ERR(0) |

Peak read throughput per cardinality:
- streams=10: 2379 MiB/s at 32 connections
- streams=100: 0 MiB/s at 8 connections

## Findings

_TODO: written by hand on top of the generated data._
