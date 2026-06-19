# DS-rust — Phase 1 raw-power benchmark report

Run directory: `results/rawpower/rawpower-slow-1781871318-10318`

> **Headroom verdict key:**
> - `server_bound ✓` — server CPU was ≥ 90 % of its allocation; this is the trustworthy ceiling.
> - `⚠️ client_capped` — server still had headroom; the number is a lower bound, NOT DS's ceiling.
> - Median ± CV% shown where REPEATS = 3 (slow profile).

## 1. Reads — throughput by message size × connections

_ops/s = aggregate reads/s across all client pods. CPU% from sidecar samples.csv._

| cell | cpu_cores | size_bytes | conns | reads/s | CPU% (sidecar) | p99 ms | verdict |
|------|-----------|-----------|-------|---------|---------------|--------|---------|
| reads-cpu4-size1024-conn256 | 4 | 1,024 | 256 | 29,222 | 285.7% | 470.01 | ⚠️ client_capped |
| reads-cpu4-size16384-conn256 | 4 | 16,384 | 256 | 2,377 | 66.6% | 5025.79 | ⚠️ client_capped |
| reads-cpu8-size1024-conn256 | 8 | 1,024 | 256 | 33,865 | 394.0% | 630.78 | ⚠️ client_capped |
| reads-cpu8-size16384-conn256 | 8 | 16,384 | 256 | 2,440 | 65.0% | 5210.11 | ⚠️ client_capped |

## 2. Read scaling by server cores

_reads/s and CPU% per server core budget (same size×conn point). Efficiency = reads/s per core._

### size=1,024 B, conn=256

| cpu_cores | reads/s | CPU% | efficiency (reads/s/core) | verdict |
|-----------|---------|------|--------------------------|---------|
| 4 | 29,222 | 285.7% | 7,306 | ⚠️ client_capped |
| 8 | 33,865 | 394.0% | 4,233 | ⚠️ client_capped |

### size=16,384 B, conn=256

| cpu_cores | reads/s | CPU% | efficiency (reads/s/core) | verdict |
|-----------|---------|------|--------------------------|---------|
| 4 | 2,377 | 66.6% | 594 | ⚠️ client_capped |
| 8 | 2,440 | 65.0% | 305 | ⚠️ client_capped |

## 3. Appends — throughput by connections × body mode

_appends/s = aggregate appends/s. CPU% from sidecar. 256-byte payload._

| cell | cpu_cores | conns | body_mode | appends/s | CPU% (sidecar) | p99 ms | verdict |
|------|-----------|-------|-----------|----------|---------------|--------|---------|
| append-cpu4-conn256-binary-p1024 | 4 | 256 | binary-p1024 | 46,027 | 198.4% | 226.94 | ⚠️ client_capped |
| append-cpu4-conn256-binary-p16384 | 4 | 256 | binary-p16384 | 33,185 | 203.3% | 323.07 | ⚠️ client_capped |
| append-cpu8-conn256-binary-p1024 | 8 | 256 | binary-p1024 | 46,470 | 218.5% | 223.10 | ⚠️ client_capped |
| append-cpu8-conn256-binary-p16384 | 8 | 256 | binary-p16384 | 35,137 | 224.0% | 314.62 | ⚠️ client_capped |

## 7. Single-stream fan-out — delivery latency vs subscriber count

_p99 = end-to-end delivery latency (writer → last subscriber). events/s = aggregate across all subscribers._

| cell | cpu_cores | subscribers | events/s | p50 ms | p99 ms | p999 ms | verdict |
|------|-----------|------------|---------|--------|--------|---------|---------|
| fanout-cpu4-subs100 | 4 | 100 | 43,629 | 139.01 | 230.27 | 918.53 | ⚠️ client_capped |
| fanout-cpu8-subs100 | 8 | 100 | 78,359 | 82.88 | 182.14 | 219.78 | ⚠️ client_capped |

## Headroom honesty summary

- **server_bound cells:** 0 — these reflect DS's true ceiling.
- **client_capped cells:** 10 — these are lower bounds; DS could do more.

### ⚠️ Client-capped cells (numbers are lower bounds)

| cell | reads/s or appends/s | CPU% | parallelism |
|------|---------------------|------|------------|
| append-cpu4-conn256-binary-p1024 | 46,027 | 198.4% | 32 |
| append-cpu4-conn256-binary-p16384 | 33,185 | 203.3% | 32 |
| append-cpu8-conn256-binary-p1024 | 46,470 | 218.5% | 32 |
| append-cpu8-conn256-binary-p16384 | 35,137 | 224.0% | 32 |
| fanout-cpu4-subs100 | - | 305.9% | 32 |
| fanout-cpu8-subs100 | - | 494.2% | 32 |
| reads-cpu4-size1024-conn256 | 29,222 | 285.7% | 32 |
| reads-cpu4-size16384-conn256 | 2,377 | 66.6% | 32 |
| reads-cpu8-size1024-conn256 | 33,865 | 394.0% | 32 |
| reads-cpu8-size16384-conn256 | 2,440 | 65.0% | 32 |

## Disclosures

- **Object tier = in-cluster MinIO on local NVMe** — near-best-case for the cold tier (low latency, no cross-AZ hop); not representative of remote cloud S3. Absolute cold-tier numbers would be lower against real cloud S3.
- **Server CPU% from sidecar, not cgroup CPUUsageNSec** — the metrics sidecar polls `/proc/<pid>/stat` cpu_ticks at intervals; CPU% = Δcpu_ticks / CLK_TCK (100) / Δelapsed_s × 100. This is per-process wall-clock CPU%, not cgroup accounting.
- **server_bound = trustworthy ceiling** — the headroom guard bumps client parallelism until the server consumes ≥ 90 % of its CPU allocation. Only server_bound cells reflect DS's true throughput ceiling. client_capped cells ran out of client pods before saturating the server — those numbers are lower bounds.
- **Where we have server_bound numbers, they reflect DS's true ceiling** — which a 3-core-wrk single-client run could not reach.
- **Median + CV% for slow profile (REPEATS=3)** — per-cell median across 3 repeats; CV% = sample_stddev/mean × 100 (÷ N-1). High CV% (> 10 %) may indicate run-to-run instability.
- **CLK_TCK = 100** assumed (standard Linux kernel default; verified via `getconf CLK_TCK` inside the container).

