# mixed-delivery — mixed read/write interference report

Sweep axis: **writer_rate**. Latency cells are p50/p99 ms. ‡ = backpressure (503/429) observed in that class.

## wal — 2000 streams

| rate/writer | write ops/s | write ms | read ops/s | read MiB/s | read ms | deliv rec/s | deliv ms | status |
|---|---|---|---|---|---|---|---|---|
| 2 | 4067 | 0.4/138.2 | 0 | 0.0 | — | 3340 | 0.4/162.6 | ok |
| 8 | 16051 | 0.5/13.8 | 0 | 0.0 | — | 13324 | 0.5/15.4 | ok |
| 20 | 39981 | 1.3/19.0 | 0 | 0.0 | — | 33211 | 1.8/21.6 | ok |
| 33 | 65910 | 9.2/29.2 | 0 | 0.0 | — | 65674 | 10.2/44.7 | ok |
| max | 86269 | 22.8/41.1 | 0 | 0.0 | — | 65537 | 37.9/57.3 | ok |

## memory — 2000 streams

| rate/writer | write ops/s | write ms | read ops/s | read MiB/s | read ms | deliv rec/s | deliv ms | status |
|---|---|---|---|---|---|---|---|---|
| 2 | 4067 | 0.4/127.2 | 0 | 0.0 | — | 3867 | 0.4/132.6 | ok |
| 8 | 16051 | 0.5/58.9 | 0 | 0.0 | — | 14677 | 0.6/334.6 | ok |
| 20 | 39931 | 11.6/82.4 | 0 | 0.0 | — | 15902 | 226.7/362.2 | ok |
| 33 | 60842 | 7.2/166.5 | 0 | 0.0 | — | 20597 | 206.6/299.3 | ok |
| max | 61627 | 9.2/166.9 | 0 | 0.0 | — | 19046 | 200.6/299.3 | ok |

## Findings

_TODO: written by hand on top of the generated data._
