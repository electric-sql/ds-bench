# canonical-mixed-writes — mixed read/write interference report

Sweep axis: **readers**. Latency cells are p50/p99 ms. ‡ = backpressure (503/429) observed in that class.

## wal — 10000 streams

| readers | write ops/s | write ms | read ops/s | read MiB/s | read ms | deliv rec/s | deliv ms | status |
|---|---|---|---|---|---|---|---|---|
| 0 | 49911 | 10.8/1701.9 | 0 | 0.0 | — | 0 | — | ok |
| 1000 | 50025 | 8.0/1419.3 | 50 | 3.1 | 2.3/399.4 | 0 | — | ok |
| 10000 | 49978 | 9.0/1516.5 | 499 | 30.4 | 2.1/413.7 | 0 | — | ok |
| 100000 | 50012 | 22.5/3770.4 | 4986 | 302.9 | 2.1/1404.9 | 0 | — | ok |

## Findings

_TODO: written by hand on top of the generated data._
