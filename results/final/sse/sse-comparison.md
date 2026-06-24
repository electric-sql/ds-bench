# SSE Fan-out — delivery latency (p99 ms)

1 stream, 1 writer @ 50 ev/s, swept total subscribers; one well-provisioned
client pod (single wall clock). Metric = delivery **p99 latency** (writer-paced).

| config \ subscribers | 1 | 10 | 100 | 1000 |
|---|---|---|---|---|
| wal (cache off) | 0.556 | 0.666 | 1.172 | 5.063 |
| wal (cache on) | 0.499 | 0.649 | 1.141 | 4.295 |
| ursula in-memory | 0.572 | 0.658 | 1.112 | 3.915 |
| ursula disk | 0.627 | 0.704 | 1.203 | 4.499 |
| s2 | — | 52.031 | 51.999 | 54.015 |

_p99 in ms; lower is better. — = not measured._
