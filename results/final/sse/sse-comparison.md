# SSE Fan-out — delivery latency

1 stream, 1 writer @ 50 ev/s, swept total subscribers; one well-provisioned
client pod (single wall clock). Writer-paced → metric is delivery latency.

## Median (p50, ms)

| config \ subscribers | 1 | 10 | 100 | 1000 |
|---|---|---|---|---|
| wal (cache off) | 0.382 | 0.481 | 0.838 | 3.597 |
| wal (cache on) | 0.321 | 0.454 | 0.792 | 2.853 |
| ursula in-memory | 0.389 | 0.493 | 0.806 | 2.673 |
| ursula disk | 0.411 | 0.497 | 0.867 | 2.945 |
| s2 | — | 51.327 | 50.911 | 52.159 |

## Full spread (p50 / p99 / max, ms)

| config | subs | p50 | p90 | p99 | p999 | max |
|---|---|---|---|---|---|---|
| wal (cache off) | 1 | 0.382 | 0.457 | 0.556 | 0.648 | 0.648 |
| wal (cache off) | 10 | 0.481 | 0.576 | 0.666 | 0.75 | 0.794 |
| wal (cache off) | 100 | 0.838 | 1.019 | 1.172 | 1.46 | 1.835 |
| wal (cache off) | 1000 | 3.597 | 4.455 | 5.063 | 5.395 | 5.847 |
| wal (cache on) | 1 | 0.321 | 0.395 | 0.499 | 0.538 | 0.538 |
| wal (cache on) | 10 | 0.454 | 0.557 | 0.649 | 0.702 | 0.747 |
| wal (cache on) | 100 | 0.792 | 0.982 | 1.141 | 1.277 | 1.399 |
| wal (cache on) | 1000 | 2.853 | 3.725 | 4.295 | 4.631 | 4.871 |
| ursula in-memory | 1 | 0.389 | 0.467 | 0.572 | 0.637 | 0.637 |
| ursula in-memory | 10 | 0.493 | 0.569 | 0.658 | 0.721 | 0.757 |
| ursula in-memory | 100 | 0.806 | 0.974 | 1.112 | 49.759 | 50.175 |
| ursula in-memory | 1000 | 2.673 | 3.435 | 3.915 | 4.187 | 5.035 |
| ursula disk | 1 | 0.411 | 0.479 | 0.627 | 1.374 | 1.374 |
| ursula disk | 10 | 0.497 | 0.584 | 0.704 | 94.975 | 95.039 |
| ursula disk | 100 | 0.867 | 1.059 | 1.203 | 2.105 | 2.393 |
| ursula disk | 1000 | 2.945 | 3.861 | 4.499 | 4.979 | 5.667 |
| s2 | 10 | 51.327 | 51.487 | 52.031 | 52.255 | 52.287 |
| s2 | 100 | 50.911 | 51.775 | 51.999 | 52.223 | 52.351 |
| s2 | 1000 | 52.159 | 53.247 | 54.015 | 54.271 | 54.399 |

_p50 = median; lower is better. — = not measured._
