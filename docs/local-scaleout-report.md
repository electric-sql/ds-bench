# DS-rust — Phase 2 scale-out benchmark report

Run directory: `results/scaleout/scaleout-fast-1781852911-82074`

> **Headroom verdict key:**
> - `server_bound ✓` — server CPU was ≥ 90 % of its allocation; this is the trustworthy ceiling.
> - `⚠️ client_capped` — server still had headroom; the number is a lower bound, NOT DS's ceiling.
> - Median ± CV% shown where REPEATS ≥ 3.

## 1. Write throughput + tail latency vs stream count

_aggregate_ops_per_sec = total appends/s across all concurrent write streams. CPU% and RSS from the server metrics sidecar._

| server_cpu | streams | aggregate_ops/s | p50 ms | p99 ms | p999 ms | merged_count | verdict |
|------------|---------|----------------|--------|--------|---------|--------------|---------|
| 2 | 10 | 171,872 | 0.00 | 0.00 | 0.00 | 0 | ⚠️ client_capped |
| 2 | 100 | 201,787 | 0.00 | 0.00 | 0.00 | 0 | ⚠️ client_capped |

## 2. Multi-stream fan-out vs (M streams × S subscribers/stream)

_aggregate_events_per_sec = total events delivered across all subscriber connections. p99 = end-to-end delivery latency (write → last subscriber)._

| server_cpu | M streams | S subs/stream | events/s | p50 ms | p99 ms | p999 ms | verdict |
|------------|-----------|--------------|---------|--------|--------|---------|---------|
| 2 | 10 | 10 | 93,487 | 15.64 | 62.30 | 73.28 | ⚠️ client_capped |

## 3. Server RSS + CPU% vs stream count

_Resource cost of scale-out: peak RSS (MiB) and mean CPU% from the server metrics sidecar. CPU% = Δcpu_ticks / CLK_TCK (100) / Δelapsed_s × 100._

| cell | rss_max_mib | cpu_pct | verdict |
|------|-------------|---------|---------|
| ms-cpu2-n10 | 678.1 | 135.3% | ⚠️ client_capped |
| ms-cpu2-n100 | 678.7 | 149.7% | ⚠️ client_capped |
| multi-fanout-cpu2-m10-s10 | 689.8 | 138.2% | ⚠️ client_capped |

## Headroom honesty summary

- **server_bound cells:** 0 — these reflect DS's true ceiling.
- **client_capped cells:** 3 — these are lower bounds; DS could do more.

### ⚠️ Client-capped cells (numbers are lower bounds)

| cell | ops/s or events/s | CPU% | parallelism |
|------|-------------------|------|------------|
| ms-cpu2-n10 | 171,872 | 135.3% | 8 |
| ms-cpu2-n100 | 201,787 | 149.7% | 8 |
| multi-fanout-cpu2-m10-s10 | 93,487 | 138.2% | 8 |

## Disclosures

- **Single-node deployment** — DS-rust server runs as a single pod on a GKE node. These numbers reflect single-node concurrent-stream capacity; multi-node distribution is deferred to Phase 3.
- **Modern NVMe storage** — the object tier is in-cluster MinIO on local NVMe (near-best-case; not representative of remote cloud S3). Cold-tier absolute numbers would be lower against real cloud S3.
- **Fleet load generator** — writer pods are a decoupled client fleet; aggregate throughput sums each pod's headline figure. Sidecar samples RSS/CPU at intervals independently of the HDR merge window.
- **Server CPU% from sidecar** — `/proc/<pid>/stat` cpu_ticks polled at intervals; CPU% = Δcpu_ticks / CLK_TCK (100) / Δelapsed_s × 100. Per-process wall-clock CPU%, not cgroup accounting.
- **server_bound = trustworthy ceiling** — the headroom guard bumps client parallelism until server CPU ≥ 90 % of its allocation. Only `server_bound ✓` cells reflect DS's true scale-out ceiling. `⚠️ client_capped` cells are lower bounds.
- **Median + CV% for slow profile (REPEATS ≥ 3)** — per-cell median across repeats; CV% = sample_stddev/mean × 100 (÷ N-1). High CV% (> 10 %) may indicate run-to-run instability.
- **CLK_TCK = 100** assumed (standard Linux kernel default).

