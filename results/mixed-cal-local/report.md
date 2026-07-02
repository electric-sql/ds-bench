# mixed-cal-local — mixed read/write interference report

Sweep axis: **writer_rate**. Latency cells are p50/p99 ms. ‡ = backpressure (503/429) observed in that class.

## wal — 50 streams

| rate/writer | write ops/s | write ms | read ops/s | read MiB/s | read ms | deliv rec/s | deliv ms | status |
|---|---|---|---|---|---|---|---|---|
| max | 23286 | 2.0/6.5 | 0 | 0.0 | — | 0 | — | ok |

## memory — 50 streams

| rate/writer | write ops/s | write ms | read ops/s | read MiB/s | read ms | deliv rec/s | deliv ms | status |
|---|---|---|---|---|---|---|---|---|
| max | 96344 | 0.5/1.6 | 0 | 0.0 | — | 0 | — | ok |

## Findings

_TODO: written by hand on top of the generated data._
