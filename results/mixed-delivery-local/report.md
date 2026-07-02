# mixed-delivery-local — mixed read/write interference report

Sweep axis: **writer_rate**. Latency cells are p50/p99 ms. ‡ = backpressure (503/429) observed in that class.

## wal — 50 streams

| rate/writer | write ops/s | write ms | read ops/s | read MiB/s | read ms | deliv rec/s | deliv ms | status |
|---|---|---|---|---|---|---|---|---|
| 30 | 1502 | 0.9/6.0 | 0 | 0.0 | — | 3005 | 1.1/7.0 | ok |
| 120 | 6002 | 1.0/11.6 | 0 | 0.0 | — | 12001 | 1.2/15.2 | ok |
| 300 | 13924 | 3.0/16.0 | 0 | 0.0 | — | 27832 | 3.7/18.2 | ok |
| 475 | 13817 | 3.1/16.4 | 0 | 0.0 | — | 27609 | 3.7/19.0 | ok |
| max | 12152 | 3.4/14.8 | 0 | 0.0 | — | 24291 | 4.2/17.1 | ok |

## memory — 50 streams

| rate/writer | write ops/s | write ms | read ops/s | read MiB/s | read ms | deliv rec/s | deliv ms | status |
|---|---|---|---|---|---|---|---|---|
| 30 | 1502 | 0.5/4.4 | 0 | 0.0 | — | 3005 | 0.9/6.9 | ok |
| 120 | 6001 | 0.5/4.5 | 0 | 0.0 | — | 11980 | 1.0/7.8 | ok |
| 300 | 15000 | 0.5/7.1 | 0 | 0.0 | — | 29118 | 1.1/13.2 | ok |
| 475 | 21426 | 1.6/30.3 | 0 | 0.0 | — | 33125 | 4.4/35.7 | ok |
| max | 20964 | 1.6/30.2 | 0 | 0.0 | — | 32717 | 4.4/36.4 | ok |

## Findings

_TODO: written by hand on top of the generated data._
