# mixed-writes — mixed read/write interference report

Sweep axis: **readers**. Latency cells are p50/p99 ms. ‡ = backpressure (503/429) observed in that class.

## wal — 10000 streams

| readers | write ops/s | write ms | read ops/s | read MiB/s | read ms | deliv rec/s | deliv ms | status |
|---|---|---|---|---|---|---|---|---|
| 0 | 49964 | 10.1/422.1 | 0 | 0.0 | — | 0 | — | ok |
| 1000 | 50026 | 11.4/441.1 | 50 | 3.0 | 0.5/418.6 | 0 | — | ok |
| 10000 | 49826 | 5.9/353.8 | 499 | 30.4 | 0.6/404.0 | 0 | — | ok |
| 100000 | 50041 | 14.9/454.7 | 4987 | 303.8 | 0.5/879.6 | 0 | — | ok |

## Findings

_TODO: written by hand on top of the generated data._
