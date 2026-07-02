# reads-catchup — read-scalability report

Each cell: aggregate read throughput (MiB/s) @ p99 latency (ms). ‡ = backpressure (503/429) observed at this load.

## wal — throughput @ p99 over stream_count × connections

| streams | 8 | 32 | 128 | 512 |
|---|---|---|---|---|
| 10 | 1345MiB/s@111ms | 2381MiB/s@237ms | ERR(0) | ERR(0) |
| 100 | 1333MiB/s@112ms | 2382MiB/s@238ms | ERR(0) | ERR(0) |

Peak read throughput per cardinality:
- streams=10: 2381 MiB/s at 32 connections
- streams=100: 2382 MiB/s at 32 connections

## ursula — throughput @ p99 over stream_count × connections

| streams | 8 | 32 | 128 | 512 |
|---|---|---|---|---|
| 10 | 2351MiB/s@86ms | 2375MiB/s@517ms | ERR(0) | ERR(0) |
| 100 | ERR(0) | ERR(0) | ERR(0) | ERR(0) |

Peak read throughput per cardinality:
- streams=10: 2375 MiB/s at 32 connections
- streams=100: 0 MiB/s at 8 connections

## Findings

_TODO: written by hand on top of the generated data._
