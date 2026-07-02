# mixed-writes-local — mixed read/write interference report

Sweep axis: **readers**. Latency cells are p50/p99 ms. ‡ = backpressure (503/429) observed in that class.

## wal — 50 streams

| readers | write ops/s | write ms | read ops/s | read ms | deliv ev/s | deliv ms | status |
|---|---|---|---|---|---|---|---|
| 0 | 12000 | 1.7/12.3 | 0 | — | 0 | — | ok |
| 4 | 11999 | 3.0/13.6 | 3920 | 0.8/4.5 | 0 | — | ok |
| 16 | 7268 | 4.7/36.0 | 7853 | 1.2/24.5 | 0 | — | ok |
| 64 | 4203 | 7.2/53.6 | 12541 | 2.9/43.6 | 0 | — | ok |
| 128 | 2168 | 14.9/89.4 | 14867 | 4.9/50.8 | 0 | — | ok |

## Findings

_See `FINDINGS.md` in this directory for the premise-by-premise conclusions and validity caveats._
