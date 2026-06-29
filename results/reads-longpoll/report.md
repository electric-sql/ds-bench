# reads-longpoll — read-scalability report

Each cell: aggregate read throughput (MiB/s) @ p99 latency (ms). ‡ = backpressure (503/429) observed at this load.

## wal — throughput @ p99 over stream_count × connections

| streams | 32 | 128 | 512 | 1024 | 2048 |
|---|---|---|---|---|---|
| 100 | 6MiB/s@5ms | 25MiB/s@6ms | 100MiB/s@6ms | 200MiB/s@6ms | 400MiB/s@8ms |
| 1000 | 4MiB/s@49ms | 16MiB/s@47ms | 65MiB/s@50ms | 130MiB/s@52ms | 240MiB/s@58ms |

Peak read throughput per cardinality:
- streams=100: 400 MiB/s at 2048 connections
- streams=1000: 240 MiB/s at 2048 connections

## ursula — throughput @ p99 over stream_count × connections

| streams | 32 | 128 | 512 | 1024 | 2048 |
|---|---|---|---|---|---|
| 100 | 2MiB/s@183ms | 11MiB/s@180ms | 40MiB/s@186ms | 78MiB/s@185ms | 161MiB/s@180ms |
| 1000 | 0MiB/s@1598ms | 2MiB/s@1390ms | 7MiB/s@1310ms | 14MiB/s@1313ms | 29MiB/s@1313ms |

Peak read throughput per cardinality:
- streams=100: 161 MiB/s at 2048 connections
- streams=1000: 29 MiB/s at 2048 connections

## Findings

_TODO: written by hand on top of the generated data._
