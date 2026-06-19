# DS-rust — Phase 1 raw-power benchmark report

Run directory: `results/rawpower/rawpower-fast-1781853031-82593`

> **Headroom verdict key:**
> - `server_bound ✓` — server CPU was ≥ 90 % of its allocation; this is the trustworthy ceiling.
> - `⚠️ client_capped` — server still had headroom; the number is a lower bound, NOT DS's ceiling.
> - Median ± CV% shown where REPEATS = 3 (slow profile).

## 1. Reads — throughput by message size × connections

_ops/s = aggregate reads/s across all client pods. CPU% from sidecar samples.csv._

| cell | cpu_cores | size_bytes | conns | reads/s | CPU% (sidecar) | p99 ms | verdict |
|------|-----------|-----------|-------|---------|---------------|--------|---------|
| reads-cpu2-size1024-conn256 | 2 | 1,024 | 256 | 29,443 | 122.2% | 219.52 | ⚠️ client_capped |

## 3. Appends — throughput by connections × body mode

_appends/s = aggregate appends/s. CPU% from sidecar. 256-byte payload._

| cell | cpu_cores | conns | body_mode | appends/s | CPU% (sidecar) | p99 ms | verdict |
|------|-----------|-------|-----------|----------|---------------|--------|---------|
| append-cpu2-conn256-binary-p1024 | 2 | 256 | binary-p1024 | 52,134 | 116.1% | 108.16 | ⚠️ client_capped |

## 7. Single-stream fan-out — delivery latency vs subscriber count

_p99 = end-to-end delivery latency (writer → last subscriber). events/s = aggregate across all subscribers._

| cell | cpu_cores | subscribers | events/s | p50 ms | p99 ms | p999 ms | verdict |
|------|-----------|------------|---------|--------|--------|---------|---------|
| fanout-cpu2-subs256 | 2 | 256 | 31,158 | 228.09 | 993.28 | 1132.54 | ⚠️ client_capped |

## Headroom honesty summary

- **server_bound cells:** 0 — these reflect DS's true ceiling.
- **client_capped cells:** 3 — these are lower bounds; DS could do more.

### ⚠️ Client-capped cells (numbers are lower bounds)

| cell | reads/s or appends/s | CPU% | parallelism |
|------|---------------------|------|------------|
| append-cpu2-conn256-binary-p1024 | 52,134 | 116.1% | 16 |
| fanout-cpu2-subs256 | - | 115.6% | 16 |
| reads-cpu2-size1024-conn256 | 29,443 | 122.2% | 16 |

## Disclosures

- **Object tier = in-cluster MinIO on local NVMe** — near-best-case for the cold tier (low latency, no cross-AZ hop); not representative of remote cloud S3. Absolute cold-tier numbers would be lower against real cloud S3.
- **Server CPU% from sidecar, not cgroup CPUUsageNSec** — the metrics sidecar polls `/proc/<pid>/stat` cpu_ticks at intervals; CPU% = Δcpu_ticks / CLK_TCK (100) / Δelapsed_s × 100. This is per-process wall-clock CPU%, not cgroup accounting.
- **server_bound = trustworthy ceiling** — the headroom guard bumps client parallelism until the server consumes ≥ 90 % of its CPU allocation. Only server_bound cells reflect DS's true throughput ceiling. client_capped cells ran out of client pods before saturating the server — those numbers are lower bounds.
- **Where we have server_bound numbers, they reflect DS's true ceiling** — which a 3-core-wrk single-client run could not reach.
- **Median + CV% for slow profile (REPEATS=3)** — per-cell median across 3 repeats; CV% = sample_stddev/mean × 100 (÷ N-1). High CV% (> 10 %) may indicate run-to-run instability.
- **CLK_TCK = 100** assumed (standard Linux kernel default; verified via `getconf CLK_TCK` inside the container).

