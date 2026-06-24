# Sustained load — sustained

_10 ops/s per stream, held 90s; 256 B payload, 1 client pod(s). Measures stability, not peak._

## Throughput + tail latency

| streams | wal ops/s | p50 | p99 | memory ops/s | p50 | p99 |
|---|---|---|---|---|---|---|
| 10 | 0.1k | 0.518 | 0.885 | 0.1k | 0.438 | 0.719 |
| 50 | 0.5k | 0.607 | 1.333 | 0.5k | 0.546 | 1.114 |
| 100 | 1.0k | 0.588 | 1.689 | 1.0k | 0.438 | 1.073 |
| 150 | 1.5k | 0.521 | 1.549 | 1.5k | 0.439 | 1.181 |

## Server memory stability (RSS, MiB) + CPU

| streams | wal peak | drift | cpu% | stable | memory peak | drift | cpu% | stable |
|---|---|---|---|---|---|---|---|---|
| 10 | 6 | 0 | 1.1 | ✅ | 6 | 0 | 1 | ✅ |
| 50 | 8 | 2 | 7.4 | ✅ | 7 | 2 | 6.7 | ✅ |
| 100 | 10 | 4 | 12.7 | ✅ | 9 | 3 | 11.3 | ✅ |
| 150 | 11 | 5 | 16.7 | ✅ | 8 | 2 | 15.6 | ✅ |

_drift = RSS(end) − RSS(start); ~0 = no leak/growth over the window._

## Errors / caveats

- None.
