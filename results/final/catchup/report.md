# Catch-up / reconnect — durable vs ursula vs s2

_Reproduces Ursula's methodology (ursula.tonbo.io/benchmark): each client reconnects to its OWN pre-populated stream and catches up via that system's native path — **ursula** `GET /bootstrap` (snapshot+tail), **durable** `offset=-1` and **s2** `/records` (full log). Equal hardware (1 server node each — Ursula's published run gave ursula 3 nodes vs 1 for DS/S2)._

## Per-client catch-up p99 latency (ms) — lower is faster

| pre_events (stream) | durable | ursula | s2 |
|---|---|---|---|
| 200 | 145.791 | 126.271 | 331.007 |
| 2000 | 925.183 | ERR(creation_choke) | ERR(creation_choke) |

## p50 latency (ms)

| pre_events | durable | ursula | s2 |
|---|---|---|---|
| 200 | 123.775 | 94.399 | 179.327 |
| 2000 | 659.455 | ERR(creation_choke) | ERR(creation_choke) |

## Aggregate replay throughput (MiB/s) — total bytes served / stampede time

| pre_events | durable | ursula | s2 |
|---|---|---|---|
| 200 | 1306.25 | 1039.17 | 1300.75 |
| 2000 | 2036.67 | ERR(creation_choke) | ERR(creation_choke) |

## Response body per client (KiB) — smaller = less to transfer

| pre_events | durable | ursula | s2 |
|---|---|---|---|
| 200 | 200 | 158 | 471.2 |
| 2000 | 2000 | ERR(creation_choke) | ERR(creation_choke) |

## Errors / caveats

- **ursula pre_events=2000**: creation_choke.
- **s2 pre_events=2000**: creation_choke.

_clients=1000 (each own stream), event_bytes=1024, snapshot_bytes=51200 (ursula only)._
## Diagnosed choke causes (from the new run-log diagnostics)
- **ursula pe=2000** — **timeout, not a crash**: the client pod was still `Running` when the window closed; the 2M-append per-client-stream setup (1000 streams × 2000 events) at 1 pod exceeds even `FLEET_TIMEOUT=600`. The ursula server was healthy. (Fix: more setup pods, or higher setup-concurrency, or fewer pre_events.)
- **s2 pe=2000** — **s2lite storage error**: `POST /v1/basins -> 500 object store error ... compacted/<id>.sst not found: 404 NoSuchKey`. s2lite's manifest references a compacted SST that the reset's MinIO bucket-wipe removed — a reset/state-consistency issue (not OOM; the 12 GiB bump fixed the earlier crashloop). (Fix: align s2lite reset with its compaction state, or skip the bucket-wipe for s2 between cells.)

## Verdict (pe=200, Ursula's point, EQUAL 1-node hardware)
| system | p99 (ms) | body (KiB) | ordering |
|---|---|---|---|
| ursula | 126 | 158 | fastest (snapshot+tail reads less) |
| durable | 146 | 200 | full-log replay |
| s2 | 331 | 471 | slowest (paginated JSON, full log) |

Ordering matches Ursula's published result (ursula < DS < S2), and body sizes line up (durable 200, s2 471, ursula 158 ≈ their 172). But on EQUAL hardware the p99 gaps are **smaller** than their published figures (ursula 1.15× faster than durable, 2.6× vs s2 — vs their 1.45× / 3.1×), because their published run gave ursula **3 nodes** vs 1 for DS/S2. Note MiB/s is *bytes moved*, not goodness: ursula's lower 1039 MiB/s reflects it reading **less** (158 KB snapshot) yet finishing fastest.
