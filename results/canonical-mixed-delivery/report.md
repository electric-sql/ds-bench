# canonical-mixed-delivery — mixed read/write interference report

Sweep axis: **writer_rate**. Latency cells are p50/p99 ms. ‡ = backpressure (503/429) observed in that class.

## wal — 2000 streams

| rate/writer | write ops/s | write ms | read ops/s | read MiB/s | read ms | deliv rec/s | deliv ms | status |
|---|---|---|---|---|---|---|---|---|
| 2 | 4067 | 1.7/146.7 | 0 | 0.0 | — | 4000 | 1.0/147.3 | ok |
| 8 | 16052 | 1.8/53.5 | 0 | 0.0 | — | 15946 | 1.1/51.1 | ok |
| 20 | 39981 | 2.4/131.1 | 0 | 0.0 | — | 33259 | 1.5/85.6 | ok |
| 33 | 65920 | 10.7/304.4 | 0 | 0.0 | — | 65682 | 10.3/91.5 | ok |
| max | 84265 | 22.4/70.5 | 0 | 0.0 | — | 64053 | 36.7/69.0 | ok |

## memory — 2000 streams

| rate/writer | write ops/s | write ms | read ops/s | read MiB/s | read ms | deliv rec/s | deliv ms | status |
|---|---|---|---|---|---|---|---|---|
| 2 | 4067 | 1.7/122.9 | 0 | 0.0 | — | 3339 | 0.9/139.5 | ok |
| 8 | 16052 | 1.8/53.5 | 0 | 0.0 | — | 15946 | 1.1/51.1 | ok |
| 20 | 39976 | 1.9/37.7 | 0 | 0.0 | — | 39817 | 1.1/4.5 | ok |
| 33 | 65894 | 2.2/63.2 | 0 | 0.0 | — | 65675 | 1.2/6.6 | ok |
| max | 139737 | 9.4/47.6 | 0 | 0.0 | — | 139265 | 11.7/62.8 | ok |

## Findings

_TODO: written by hand on top of the generated data._
