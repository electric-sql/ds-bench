# SSE Fan-out — delivery latency

1 stream, 1 writer @ 50 ev/s, swept total subscribers; one well-provisioned
client pod (single wall clock). Writer-paced → metric is delivery latency.

## Median (p50, ms)

| config \ subscribers | 1 | 10 | 100 | 1000 |
|---|---|---|---|---|
| wal (cache off) | 0.359 | 0.482 | 0.905 | 3.645 |
| ursula in-memory | 0.396 | 0.504 | 0.835 | 2.979 |
| ursula disk | 1.307 | 1.822 | 2.135 | 4.247 |

## Full spread (p50 / p99 / max, ms)

| config | subs | p50 | p90 | p99 | p999 | max |
|---|---|---|---|---|---|---|
| wal (cache off) | 1 | 0.359 | 0.449 | 0.577 | 0.904 | 0.904 |
| wal (cache off) | 10 | 0.482 | 0.598 | 0.717 | 0.855 | 0.931 |
| wal (cache off) | 100 | 0.905 | 1.113 | 1.276 | 1.408 | 1.685 |
| wal (cache off) | 1000 | 3.645 | 4.531 | 5.079 | 5.387 | 5.743 |
| ursula in-memory | 1 | 0.396 | 0.487 | 0.589 | 0.745 | 0.745 |
| ursula in-memory | 10 | 0.504 | 0.621 | 0.748 | 42.623 | 42.719 |
| ursula in-memory | 100 | 0.835 | 1.036 | 1.192 | 1.968 | 2.191 |
| ursula in-memory | 1000 | 2.979 | 3.899 | 4.511 | 4.831 | 5.427 |
| ursula disk | 1 | 1.307 | 1.41 | 1.528 | 2.315 | 2.315 |
| ursula disk | 10 | 1.822 | 1.976 | 2.261 | 41.215 | 41.247 |
| ursula disk | 100 | 2.135 | 2.391 | 2.761 | 3.373 | 3.605 |
| ursula disk | 1000 | 4.247 | 5.199 | 5.867 | 6.503 | 7.611 |

## Pod memory vs subscribers — peak / p50 (MiB)

| config \ subscribers | 1 | 10 | 100 | 1000 |
|---|---|---|---|---|
| wal (cache off) | 6 / 5 | 7 / 6 | 10 / 9 | 19 / 18 |
| ursula in-memory | 14 / 13 | 14 / 13 | 14 / 13 | 14 / 13 |
| ursula disk | 15 / 14 | 14 / 14 | 14 / 13 | 14 / 13 |

_Pod working set (cgroup `memory.current − inactive_file`) during each subscriber-count cell. **Flat across the row ⇒ a shared fan-out buffer** (one resident tail served to all subscribers); growth ⇒ per-subscriber buffering._


_p50 = median; lower is better. — = not measured._
