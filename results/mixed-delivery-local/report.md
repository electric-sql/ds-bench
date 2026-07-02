# mixed-delivery-local — mixed read/write interference report

Sweep axis: **writer_rate**. Latency cells are p50/p99 ms. ‡ = backpressure (503/429) observed in that class.

## wal — 50 streams

| rate/writer | write ops/s | write ms | read ops/s | read ms | deliv ev/s | deliv ms | status |
|---|---|---|---|---|---|---|---|
| 20 | 909 | 2.0/12.9 | 0 | — | 3639 | 2.3/14.1 | ok |
| 80 | 3628 | 1.2/14.9 | 0 | — | 14515 | 1.4/16.8 | ok |
| 200 | 9073 | 1.4/11.8 | 0 | — | 36294 | 1.7/13.7 | ok |
| 315 | 13562 | 2.7/14.7 | 0 | — | 54242 | 3.2/17.3 | ok |
| max | 14883 | 2.6/12.8 | 0 | — | 59528 | 3.0/14.0 | ok |

## Findings

_See `FINDINGS.md` in this directory for the premise-by-premise conclusions and validity caveats._
