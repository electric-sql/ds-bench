# DS-rust — Phase 1 raw-power benchmark report

Run directory: `results/rawpower/rawpower-slow-1781825882-38304`

> **Headroom verdict key:**
> - `server_bound ✓` — server CPU was ≥ 90 % of its allocation; this is the trustworthy ceiling.
> - `⚠️ client_capped` — server still had headroom; the number is a lower bound, NOT DS's ceiling.
> - Median ± CV% shown where REPEATS = 3 (slow profile).

## 1. Reads — throughput by message size × connections

_ops/s = aggregate reads/s across all client pods. CPU% from sidecar samples.csv._

| cell | cpu_cores | size_bytes | conns | reads/s | CPU% (sidecar) | p99 ms | verdict |
|------|-----------|-----------|-------|---------|---------------|--------|---------|
| reads-cpu2-size1024-conn16 | 2 | 1,024 | 16 | 28,934 | 143.9% | 41.98 | ⚠️ client_capped |
| reads-cpu2-size1024-conn64 | 2 | 1,024 | 64 | 27,942 | 149.4% | 52.16 | ⚠️ client_capped |
| reads-cpu2-size1024-conn256 | 2 | 1,024 | 256 | 26,694 | 149.5% | 62.85 | ⚠️ client_capped |
| reads-cpu2-size16384-conn16 | 2 | 16,384 | 16 | 23,257 | 147.6% | 21.33 | ⚠️ client_capped |
| reads-cpu2-size16384-conn64 | 2 | 16,384 | 64 | 22,527 | 141.9% | 36.06 | ⚠️ client_capped |
| reads-cpu2-size16384-conn256 | 2 | 16,384 | 256 | 22,066 | 140.8% | 66.81 | ⚠️ client_capped |

## 3. Appends — throughput by connections × body mode

_appends/s = aggregate appends/s. CPU% from sidecar. 256-byte payload._

| cell | cpu_cores | conns | body_mode | appends/s | CPU% (sidecar) | p99 ms | verdict |
|------|-----------|-------|-----------|----------|---------------|--------|---------|
| append-cpu2-conn64-binary-p1024 | 2 | 64 | binary-p1024 | 9,406 | 28.0% | 11.96 | ⚠️ client_capped |
| append-cpu2-conn64-json-single-p1024 | 2 | 64 | json-single-p1024 | - | - | - | - |

## Headroom honesty summary

- **server_bound cells:** 0 — these reflect DS's true ceiling.
- **client_capped cells:** 7 — these are lower bounds; DS could do more.

### ⚠️ Client-capped cells (numbers are lower bounds)

| cell | reads/s or appends/s | CPU% | parallelism |
|------|---------------------|------|------------|
| append-cpu2-conn64-binary-p1024 | 9,406 | 28.0% | 2 |
| reads-cpu2-size1024-conn16 | 28,934 | 143.9% | 2 |
| reads-cpu2-size1024-conn256 | 26,694 | 149.5% | 2 |
| reads-cpu2-size1024-conn64 | 27,942 | 149.4% | 2 |
| reads-cpu2-size16384-conn16 | 23,257 | 147.6% | 2 |
| reads-cpu2-size16384-conn256 | 22,066 | 140.8% | 2 |
| reads-cpu2-size16384-conn64 | 22,527 | 141.9% | 2 |

## Disclosures

- **Object tier = in-cluster MinIO on local NVMe** — near-best-case for the cold tier (low latency, no cross-AZ hop); not representative of remote cloud S3. Absolute cold-tier numbers would be lower against real cloud S3.
- **Server CPU% from sidecar, not cgroup CPUUsageNSec** — the metrics sidecar polls `/proc/<pid>/stat` cpu_ticks at intervals; CPU% = Δcpu_ticks / CLK_TCK (100) / Δelapsed_s × 100. This is per-process wall-clock CPU%, not cgroup accounting.
- **server_bound = trustworthy ceiling** — the headroom guard bumps client parallelism until the server consumes ≥ 90 % of its CPU allocation. Only server_bound cells reflect DS's true throughput ceiling. client_capped cells ran out of client pods before saturating the server — those numbers are lower bounds.
- **Where we have server_bound numbers, they reflect DS's true ceiling** — which a 3-core-wrk single-client run could not reach.
- **Median + CV% for slow profile (REPEATS=3)** — per-cell median across 3 repeats; CV% = sample_stddev/mean × 100 (÷ N-1). High CV% (> 10 %) may indicate run-to-run instability.
- **CLK_TCK = 100** assumed (standard Linux kernel default; verified via `getconf CLK_TCK` inside the container).
