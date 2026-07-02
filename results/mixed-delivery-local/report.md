# mixed-delivery-local — mixed read/write interference report

Sweep axis: **writer_rate**. Latency cells are p50/p99 ms. ‡ = backpressure (503/429) observed in that class.

## wal — 50 streams

| rate/writer | write ops/s | write ms | read ops/s | read MiB/s | read ms | deliv rec/s | deliv ms | status |
|---|---|---|---|---|---|---|---|---|
| 30 | 1502 | 2.4/9.7 | 0 | 0.0 | — | 3005 | 3.2/12.4 | ok |
| 120 | 6002 | 0.7/7.9 | 0 | 0.0 | — | 12003 | 0.9/10.1 | ok |
| 300 | 14741 | 1.7/13.8 | 0 | 0.0 | — | 29475 | 2.1/17.2 | ok |
| 475 | 17380 | 2.3/19.1 | 0 | 0.0 | — | 34746 | 2.8/20.9 | ok |
| max | 17144 | 2.3/20.3 | 0 | 0.0 | — | 34273 | 2.8/22.6 | ok |

## memory — 50 streams

| rate/writer | write ops/s | write ms | read ops/s | read MiB/s | read ms | deliv rec/s | deliv ms | status |
|---|---|---|---|---|---|---|---|---|
| 30 | 1502 | 0.7/5.7 | 0 | 0.0 | — | 3005 | 1.4/8.7 | ok |
| 120 | 6002 | 0.4/2.1 | 0 | 0.0 | — | 12000 | 0.8/3.5 | ok |
| 300 | 15001 | 0.4/2.7 | 0 | 0.0 | — | 29477 | 0.9/5.1 | ok |
| 475 | 23752 | 0.6/3.8 | 0 | 0.0 | — | 44982 | 1.3/8.5 | ok |
| max | 29247 | 1.2/30.0 | 0 | 0.0 | — | 44328 | 3.3/34.8 | ok |

## Findings

_See `FINDINGS.md` in this directory for the premise-by-premise conclusions and validity caveats._
