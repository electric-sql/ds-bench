# canonical-mixed-delivery — mixed read/write interference report

Sweep axis: **writer_rate**. Latency cells are p50/p99 ms. ‡ = backpressure (503/429) observed in that class.

## wal — 2000 streams

| rate/writer | write ops/s | write ms | read ops/s | read MiB/s | read ms | deliv rec/s | deliv ms | status |
|---|---|---|---|---|---|---|---|---|
| 2 | 4067 | 1.7/121.2 | 0 | 0.0 | — | 3336 | 1.0/137.5 | ok |
| 8 | 16049 | 1.7/58.1 | 0 | 0.0 | — | 15944 | 1.1/54.2 | ok |
| 20 | 39978 | 2.3/135.8 | 0 | 0.0 | — | 33262 | 1.4/86.1 | ok |
| 33 | 65915 | 10.1/262.4 | 0 | 0.0 | — | 54853 | 10.1/107.1 | ok |
| max | 85168 | 21.9/95.9 | 0 | 0.0 | — | 63848 | 35.8/105.6 | ok |

## memory — 2000 streams

| rate/writer | write ops/s | write ms | read ops/s | read MiB/s | read ms | deliv rec/s | deliv ms | status |
|---|---|---|---|---|---|---|---|---|
| 2 | 4067 | 1.7/129.4 | 0 | 0.0 | — | 3341 | 0.9/150.7 | ok |
| 8 | 16047 | 1.7/3.8 | 0 | 0.0 | — | 13305 | 1.0/5.1 | ok |
| 20 | 39985 | 1.8/3.0 | 0 | 0.0 | — | 33226 | 1.1/2.3 | ok |
| 33 | 65920 | 2.1/93.8 | 0 | 0.0 | — | 65691 | 1.2/8.4 | ok |
| max | 127139 | 14.5/41.3 | 0 | 0.0 | — | 126730 | 12.0/45.0 | ok |

## Findings

_TODO: written by hand on top of the generated data._
