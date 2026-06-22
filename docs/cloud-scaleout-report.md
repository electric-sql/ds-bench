# DS-rust — Phase 2 scale-out benchmark report

Run directory: `results/scaleout/scaleout-slow-1781886552-55988`

> **Headroom verdict key:**
> - `server_bound ✓` — server CPU was ≥ 90 % of its allocation; this is the trustworthy ceiling.
> - `⚠️ client_capped` — server still had headroom; the number is a lower bound, NOT DS's ceiling.
> - Median ± CV% shown where REPEATS ≥ 3.

## 1. Write throughput + tail latency vs stream count

_aggregate_ops_per_sec = total appends/s across all concurrent write streams. CPU% and RSS from the server metrics sidecar._

| server_cpu | streams | aggregate_ops/s | p50 ms | p99 ms | p999 ms | merged_count | verdict |
|------------|---------|----------------|--------|--------|---------|--------------|---------|
| 8 | 10 | 232,570 | 0.00 | 0.00 | 0.00 | 0 | ⚠️ client_capped |
| 8 | 100 | 258,801 | 0.00 | 0.00 | 0.00 | 0 | ⚠️ client_capped |
| 8 | 1000 | 219,091 | 0.00 | 0.00 | 0.00 | 0 | ⚠️ client_capped |
| 8 | 10000 | 42,109 | 0.00 | 0.00 | 0.00 | 0 | ⚠️ client_capped |

## 2. Multi-stream fan-out vs (M streams × S subscribers/stream)

_aggregate_events_per_sec = total events delivered across all subscriber connections. p99 = end-to-end delivery latency (write → last subscriber)._

| server_cpu | M streams | S subs/stream | events/s | p50 ms | p99 ms | p999 ms | verdict |
|------------|-----------|--------------|---------|--------|--------|---------|---------|
| 8 | 10 | 100 | 220,414 | 223.23 | 2046.97 | 4685.82 | ⚠️ client_capped |
| 8 | 100 | 10 | 154,291 | 280.83 | 982.53 | 1771.52 | ⚠️ client_capped |

## 3. Server RSS + CPU% vs stream count

_Resource cost of scale-out: peak RSS (MiB) and mean CPU% from the server metrics sidecar. CPU% = Δcpu_ticks / CLK_TCK (100) / Δelapsed_s × 100._

| cell | rss_max_mib | cpu_pct | verdict |
|------|-------------|---------|---------|
| ms-cpu8-n10 | 105.7 | 447.2% | ⚠️ client_capped |
| ms-cpu8-n100 | 115.6 | 513.7% | ⚠️ client_capped |
| ms-cpu8-n1000 | 268.1 | 506.4% | ⚠️ client_capped |
| ms-cpu8-n10000 | 597.3 | 125.6% | ⚠️ client_capped |
| multi-fanout-cpu8-m10-s100 | 1290.4 | 495.8% | ⚠️ client_capped |
| multi-fanout-cpu8-m100-s10 | 1067.8 | 437.9% | ⚠️ client_capped |

## Headroom honesty summary

- **server_bound cells:** 0 — these reflect DS's true ceiling.
- **client_capped cells:** 6 — these are lower bounds; DS could do more.

### ⚠️ Client-capped cells (numbers are lower bounds)

| cell | ops/s or events/s | CPU% | parallelism |
|------|-------------------|------|------------|
| ms-cpu8-n10 | 232,570 | 447.2% | 16 |
| ms-cpu8-n100 | 258,801 | 513.7% | 16 |
| ms-cpu8-n1000 | 219,091 | 506.4% | 16 |
| ms-cpu8-n10000 | 42,109 | 125.6% | 16 |
| multi-fanout-cpu8-m10-s100 | 220,414 | 495.8% | 16 |
| multi-fanout-cpu8-m100-s10 | 154,291 | 437.9% | 16 |

## Disclosures

- **Single-node deployment** — DS-rust server runs as a single pod on a GKE node. These numbers reflect single-node concurrent-stream capacity; multi-node distribution is deferred to Phase 3.
- **Modern NVMe storage** — the object tier is in-cluster MinIO on local NVMe (near-best-case; not representative of remote cloud S3). Cold-tier absolute numbers would be lower against real cloud S3.
- **Fleet load generator** — writer pods are a decoupled client fleet; aggregate throughput sums each pod's headline figure. Sidecar samples RSS/CPU at intervals independently of the HDR merge window.
- **Server CPU% from sidecar** — `/proc/<pid>/stat` cpu_ticks polled at intervals; CPU% = Δcpu_ticks / CLK_TCK (100) / Δelapsed_s × 100. Per-process wall-clock CPU%, not cgroup accounting.
- **server_bound = trustworthy ceiling** — the headroom guard bumps client parallelism until server CPU ≥ 90 % of its allocation. Only `server_bound ✓` cells reflect DS's true scale-out ceiling. `⚠️ client_capped` cells are lower bounds.
- **Median + CV% for slow profile (REPEATS ≥ 3)** — per-cell median across repeats; CV% = sample_stddev/mean × 100 (÷ N-1). High CV% (> 10 %) may indicate run-to-run instability.
- **CLK_TCK = 100** assumed (standard Linux kernel default).

