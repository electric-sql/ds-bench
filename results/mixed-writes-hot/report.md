# mixed-writes-hot — mixed read/write interference report

Sweep axis: **readers**. Latency cells are p50/p99 ms. ‡ = backpressure (503/429) observed in that class.

## wal — 50 streams

| readers | write ops/s | write ms | read ops/s | read MiB/s | read ms | deliv rec/s | deliv ms | status |
|---|---|---|---|---|---|---|---|---|
| 16 | 48874 | 0.4/1.7 | 2139 | 2342.6 | 3.6/38.6 | 0 | — | ok |
| 64 | 47715 | 0.5/9.6 | 2252 | 2321.5 | 11.1/223.7 | 0 | — | ok |
| 256 | 7655 | 3.6/35.4 | 6133 | 2282.3 | 30.7/183.0 | 0 | — | ok |

## Findings

_TODO: written by hand on top of the generated data._
