# mixed-writes-local — mixed read/write interference report

Sweep axis: **readers**. Latency cells are p50/p99 ms. ‡ = backpressure (503/429) observed in that class.

## wal — 50 streams

| readers | write ops/s | write ms | read ops/s | read MiB/s | read ms | deliv rec/s | deliv ms | status |
|---|---|---|---|---|---|---|---|---|
| 0 | 17303 | 1.2/9.8 | 0 | 0.0 | — | 0 | — | ok |
| 4 | 17755 | 1.0/5.7 | 4 | 3.8 | 1.7/10.5 | 0 | — | ok |
| 16 | 17756 | 0.9/5.3 | 17 | 15.4 | 3.9/17.1 | 0 | — | ok |
| 64 | 17756 | 1.0/6.5 | 67 | 61.5 | 5.5/65.5 | 0 | — | ok |
| 128 | 17750 | 1.1/52.9 | 134 | 123.0 | 4.9/50.9 | 0 | — | ok |

## Findings

_See `FINDINGS.md` in this directory for the premise-by-premise conclusions and validity caveats._
