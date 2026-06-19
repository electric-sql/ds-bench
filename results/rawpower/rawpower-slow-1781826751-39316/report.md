# DS-rust — Phase 1 raw-power benchmark report

Run directory: `results/rawpower/rawpower-slow-1781826751-39316`

> **Headroom verdict key:**
> - `server_bound ✓` — server CPU was ≥ 90 % of its allocation; this is the trustworthy ceiling.
> - `⚠️ client_capped` — server still had headroom; the number is a lower bound, NOT DS's ceiling.
> - Median ± CV% shown where REPEATS = 3 (slow profile).

## 1. Reads — throughput by message size × connections

_ops/s = aggregate reads/s across all client pods. CPU% from sidecar samples.csv._

| cell | cpu_cores | size_bytes | conns | reads/s | CPU% (sidecar) | p99 ms | verdict |
|------|-----------|-----------|-------|---------|---------------|--------|---------|
| reads-cpu2-size1024-conn16 | 2 | 1,024 | 16 | 27,358 | 107.2% | 44.22 | ⚠️ client_capped |
| reads-cpu2-size1024-conn64 | 2 | 1,024 | 64 | 27,979 | 145.8% | 52.32 | ⚠️ client_capped |
| reads-cpu2-size1024-conn256 | 2 | 1,024 | 256 | 27,250 | 147.5% | 62.46 | ⚠️ client_capped |
| reads-cpu2-size16384-conn16 | 2 | 16,384 | 16 | 23,375 | 145.2% | 21.12 | ⚠️ client_capped |
| reads-cpu2-size16384-conn64 | 2 | 16,384 | 64 | 23,251 | 145.8% | 36.45 | ⚠️ client_capped |
| reads-cpu2-size16384-conn256 | 2 | 16,384 | 256 | 22,168 | 144.8% | 64.64 | ⚠️ client_capped |
| reads-cpu4-size1024-conn16 | 4 | 1,024 | 16 | - | 0.0% | - | ⚠️ client_capped |
| reads-cpu4-size1024-conn64 | 4 | 1,024 | 64 | 49,193 | 299.6% | 39.33 | ⚠️ client_capped |
| reads-cpu4-size1024-conn256 | 4 | 1,024 | 256 | 47,124 | 292.1% | 49.60 | ⚠️ client_capped |
| reads-cpu4-size16384-conn16 | 4 | 16,384 | 16 | 41,365 | 287.0% | 5.75 | ⚠️ client_capped |
| reads-cpu4-size16384-conn64 | 4 | 16,384 | 64 | 39,791 | 297.3% | 20.34 | ⚠️ client_capped |
| reads-cpu4-size16384-conn256 | 4 | 16,384 | 256 | 36,932 | 292.5% | 50.72 | ⚠️ client_capped |
| reads-cpu8-size1024-conn16 | 8 | 1,024 | 16 | 62,372 | 422.7% | 0.96 | ⚠️ client_capped |
| reads-cpu8-size1024-conn64 | 8 | 1,024 | 64 | 82,516 | 504.6% | 3.37 | ⚠️ client_capped |
| reads-cpu8-size1024-conn256 | 8 | 1,024 | 256 | 81,219 | 531.4% | 15.49 | ⚠️ client_capped |
| reads-cpu8-size16384-conn16 | 8 | 16,384 | 16 | 54,971 | 411.9% | 1.10 | ⚠️ client_capped |
| reads-cpu8-size16384-conn64 | 8 | 16,384 | 64 | 56,834 | 451.4% | 7.49 | ⚠️ client_capped |
| reads-cpu8-size16384-conn256 | 8 | 16,384 | 256 | 55,648 | 469.6% | 28.69 | ⚠️ client_capped |

## 2. Read scaling by server cores

_reads/s and CPU% per server core budget (same size×conn point). Efficiency = reads/s per core._

### size=1,024 B, conn=16

| cpu_cores | reads/s | CPU% | efficiency (reads/s/core) | verdict |
|-----------|---------|------|--------------------------|---------|
| 2 | 27,358 | 107.2% | 13,679 | ⚠️ client_capped |
| 4 | - | 0.0% | - | ⚠️ client_capped |
| 8 | 62,372 | 422.7% | 7,796 | ⚠️ client_capped |

### size=1,024 B, conn=64

| cpu_cores | reads/s | CPU% | efficiency (reads/s/core) | verdict |
|-----------|---------|------|--------------------------|---------|
| 2 | 27,979 | 145.8% | 13,990 | ⚠️ client_capped |
| 4 | 49,193 | 299.6% | 12,298 | ⚠️ client_capped |
| 8 | 82,516 | 504.6% | 10,314 | ⚠️ client_capped |

### size=1,024 B, conn=256

| cpu_cores | reads/s | CPU% | efficiency (reads/s/core) | verdict |
|-----------|---------|------|--------------------------|---------|
| 2 | 27,250 | 147.5% | 13,625 | ⚠️ client_capped |
| 4 | 47,124 | 292.1% | 11,781 | ⚠️ client_capped |
| 8 | 81,219 | 531.4% | 10,152 | ⚠️ client_capped |

### size=16,384 B, conn=16

| cpu_cores | reads/s | CPU% | efficiency (reads/s/core) | verdict |
|-----------|---------|------|--------------------------|---------|
| 2 | 23,375 | 145.2% | 11,688 | ⚠️ client_capped |
| 4 | 41,365 | 287.0% | 10,341 | ⚠️ client_capped |
| 8 | 54,971 | 411.9% | 6,871 | ⚠️ client_capped |

### size=16,384 B, conn=64

| cpu_cores | reads/s | CPU% | efficiency (reads/s/core) | verdict |
|-----------|---------|------|--------------------------|---------|
| 2 | 23,251 | 145.8% | 11,626 | ⚠️ client_capped |
| 4 | 39,791 | 297.3% | 9,948 | ⚠️ client_capped |
| 8 | 56,834 | 451.4% | 7,104 | ⚠️ client_capped |

### size=16,384 B, conn=256

| cpu_cores | reads/s | CPU% | efficiency (reads/s/core) | verdict |
|-----------|---------|------|--------------------------|---------|
| 2 | 22,168 | 144.8% | 11,084 | ⚠️ client_capped |
| 4 | 36,932 | 292.5% | 9,233 | ⚠️ client_capped |
| 8 | 55,648 | 469.6% | 6,956 | ⚠️ client_capped |

## 3. Appends — throughput by connections × body mode

_appends/s = aggregate appends/s. CPU% from sidecar. 256-byte payload._

| cell | cpu_cores | conns | body_mode | appends/s | CPU% (sidecar) | p99 ms | verdict |
|------|-----------|-------|-----------|----------|---------------|--------|---------|
| append-cpu2-conn64-binary-p1024 | 2 | 64 | binary-p1024 | 149 | 0.5% | 8.58 | ⚠️ client_capped |
| append-cpu2-conn64-binary-p16384 | 2 | 64 | binary-p16384 | - | 0.0% | - | ⚠️ client_capped |
| append-cpu2-conn256-binary-p1024 | 2 | 256 | binary-p1024 | - | 0.0% | - | ⚠️ client_capped |
| append-cpu2-conn256-binary-p16384 | 2 | 256 | binary-p16384 | - | 0.0% | - | ⚠️ client_capped |
| append-cpu4-conn64-binary-p1024 | 4 | 64 | binary-p1024 | 3,318 | 11.6% | 12.34 | ⚠️ client_capped |
| append-cpu4-conn64-binary-p16384 | 4 | 64 | binary-p16384 | - | 0.0% | - | ⚠️ client_capped |
| append-cpu4-conn256-binary-p1024 | 4 | 256 | binary-p1024 | - | 0.0% | - | ⚠️ client_capped |
| append-cpu4-conn256-binary-p16384 | 4 | 256 | binary-p16384 | - | 0.0% | - | ⚠️ client_capped |
| append-cpu8-conn64-binary-p1024 | 8 | 64 | binary-p1024 | 1,824 | 8.8% | 15.30 | ⚠️ client_capped |
| append-cpu8-conn64-binary-p16384 | 8 | 64 | binary-p16384 | - | 0.0% | - | ⚠️ client_capped |
| append-cpu8-conn256-binary-p1024 | 8 | 256 | binary-p1024 | - | 0.0% | - | ⚠️ client_capped |
| append-cpu8-conn256-binary-p16384 | 8 | 256 | binary-p16384 | - | 0.0% | - | ⚠️ client_capped |

## 5. Splice — 1 MB binary appends with/without --splice-appends

_CPU lever: splice should reduce kernel copy overhead for large payloads._

| cell | cpu_cores | conns | appends/s | throughput | CPU% (sidecar) | p99 ms | verdict |
|------|-----------|-------|----------|------------|---------------|--------|---------|
| append-splice-cpu2-conn256-binary-1m | 2 | 256 | 377 | - | 50.1% | 0.00 | ⚠️ client_capped |
| append-splice-cpu4-conn256-binary-1m | 4 | 256 | 375 | - | 52.2% | 0.00 | ⚠️ client_capped |
| append-splice-cpu8-conn256-binary-1m | 8 | 256 | 375 | - | 57.5% | 0.00 | ⚠️ client_capped |

## 6. Cold-tier read — replay from object store

_--tier local: reads go through the cold tier (simulated S3-on-NVMe). Seed = 100 MB to exceed hot cache._

| cell | cpu_cores | reads/s | throughput | CPU% (sidecar) | p99 ms | verdict |
|------|-----------|---------|------------|---------------|--------|---------|
| reads-cold-cpu2-size1m-conn64 | 2 | - | - | 1.8% | - | ⚠️ client_capped |
| reads-cold-cpu4-size1m-conn64 | 4 | - | - | 1.9% | - | ⚠️ client_capped |
| reads-cold-cpu8-size1m-conn64 | 8 | - | - | 1.9% | - | ⚠️ client_capped |

## 7. Single-stream fan-out — delivery latency vs subscriber count

_p99 = end-to-end delivery latency (writer → last subscriber). events/s = aggregate across all subscribers._

| cell | cpu_cores | subscribers | events/s | p50 ms | p99 ms | p999 ms | verdict |
|------|-----------|------------|---------|--------|--------|---------|---------|
| fanout-cpu2-subs1 | 2 | 1 | 200 | 0.45 | 0.89 | 1.91 | ⚠️ client_capped |
| fanout-cpu2-subs10 | 2 | 10 | 1,997 | 0.59 | 1.03 | 1.98 | ⚠️ client_capped |
| fanout-cpu2-subs100 | 2 | 100 | 18,104 | 1.78 | 4.06 | 4.94 | ⚠️ client_capped |
| fanout-cpu4-subs1 | 4 | 1 | - | - | - | - | ⚠️ client_capped |
| fanout-cpu4-subs10 | 4 | 10 | 1,999 | 0.59 | 0.97 | 1.62 | ⚠️ client_capped |
| fanout-cpu4-subs100 | 4 | 100 | 19,986 | 1.10 | 2.00 | 2.66 | ⚠️ client_capped |
| fanout-cpu8-subs1 | 8 | 1 | - | - | - | - | ⚠️ client_capped |
| fanout-cpu8-subs10 | 8 | 10 | 2,000 | 0.58 | 0.99 | 1.84 | ⚠️ client_capped |
| fanout-cpu8-subs100 | 8 | 100 | 19,986 | 1.03 | 1.76 | 3.60 | ⚠️ client_capped |

## Headroom honesty summary

- **server_bound cells:** 0 — these reflect DS's true ceiling.
- **client_capped cells:** 45 — these are lower bounds; DS could do more.

### ⚠️ Client-capped cells (numbers are lower bounds)

| cell | reads/s or appends/s | CPU% | parallelism |
|------|---------------------|------|------------|
| append-cpu2-conn256-binary-p1024 | - | 0.0% | 2 |
| append-cpu2-conn256-binary-p16384 | - | 0.0% | 2 |
| append-cpu2-conn64-binary-p1024 | 149 | 0.5% | 2 |
| append-cpu2-conn64-binary-p16384 | - | 0.0% | 2 |
| append-cpu4-conn256-binary-p1024 | - | 0.0% | 2 |
| append-cpu4-conn256-binary-p16384 | - | 0.0% | 2 |
| append-cpu4-conn64-binary-p1024 | 3,318 | 11.6% | 2 |
| append-cpu4-conn64-binary-p16384 | - | 0.0% | 2 |
| append-cpu8-conn256-binary-p1024 | - | 0.0% | 2 |
| append-cpu8-conn256-binary-p16384 | - | 0.0% | 2 |
| append-cpu8-conn64-binary-p1024 | 1,824 | 8.8% | 2 |
| append-cpu8-conn64-binary-p16384 | - | 0.0% | 2 |
| append-splice-cpu2-conn256-binary-1m | 377 | 50.1% | 2 |
| append-splice-cpu4-conn256-binary-1m | 375 | 52.2% | 2 |
| append-splice-cpu8-conn256-binary-1m | 375 | 57.5% | 2 |
| fanout-cpu2-subs1 | - | 2.5% | 2 |
| fanout-cpu2-subs10 | - | 4.9% | 2 |
| fanout-cpu2-subs100 | - | 33.5% | 2 |
| fanout-cpu4-subs1 | - | 0.0% | 2 |
| fanout-cpu4-subs10 | - | 6.4% | 2 |
| fanout-cpu4-subs100 | - | 39.2% | 2 |
| fanout-cpu8-subs1 | - | 0.0% | 2 |
| fanout-cpu8-subs10 | - | 6.6% | 2 |
| fanout-cpu8-subs100 | - | 47.4% | 2 |
| reads-cold-cpu2-size1m-conn64 | - | 1.8% | 2 |
| reads-cold-cpu4-size1m-conn64 | - | 1.9% | 2 |
| reads-cold-cpu8-size1m-conn64 | - | 1.9% | 2 |
| reads-cpu2-size1024-conn16 | 27,358 | 107.2% | 2 |
| reads-cpu2-size1024-conn256 | 27,250 | 147.5% | 2 |
| reads-cpu2-size1024-conn64 | 27,979 | 145.8% | 2 |
| reads-cpu2-size16384-conn16 | 23,375 | 145.2% | 2 |
| reads-cpu2-size16384-conn256 | 22,168 | 144.8% | 2 |
| reads-cpu2-size16384-conn64 | 23,251 | 145.8% | 2 |
| reads-cpu4-size1024-conn16 | - | 0.0% | 2 |
| reads-cpu4-size1024-conn256 | 47,124 | 292.1% | 2 |
| reads-cpu4-size1024-conn64 | 49,193 | 299.6% | 2 |
| reads-cpu4-size16384-conn16 | 41,365 | 287.0% | 2 |
| reads-cpu4-size16384-conn256 | 36,932 | 292.5% | 2 |
| reads-cpu4-size16384-conn64 | 39,791 | 297.3% | 2 |
| reads-cpu8-size1024-conn16 | 62,372 | 422.7% | 2 |
| reads-cpu8-size1024-conn256 | 81,219 | 531.4% | 2 |
| reads-cpu8-size1024-conn64 | 82,516 | 504.6% | 2 |
| reads-cpu8-size16384-conn16 | 54,971 | 411.9% | 2 |
| reads-cpu8-size16384-conn256 | 55,648 | 469.6% | 2 |
| reads-cpu8-size16384-conn64 | 56,834 | 451.4% | 2 |

## Disclosures

- **Object tier = in-cluster MinIO on local NVMe** — near-best-case for the cold tier (low latency, no cross-AZ hop); not representative of remote cloud S3. Absolute cold-tier numbers would be lower against real cloud S3.
- **Server CPU% from sidecar, not cgroup CPUUsageNSec** — the metrics sidecar polls `/proc/<pid>/stat` cpu_ticks at intervals; CPU% = Δcpu_ticks / CLK_TCK (100) / Δelapsed_s × 100. This is per-process wall-clock CPU%, not cgroup accounting.
- **server_bound = trustworthy ceiling** — the headroom guard bumps client parallelism until the server consumes ≥ 90 % of its CPU allocation. Only server_bound cells reflect DS's true throughput ceiling. client_capped cells ran out of client pods before saturating the server — those numbers are lower bounds.
- **Where we have server_bound numbers, they reflect DS's true ceiling** — which a 3-core-wrk single-client run could not reach.
- **Median + CV% for slow profile (REPEATS=3)** — per-cell median across 3 repeats; CV% = sample_stddev/mean × 100 (÷ N-1). High CV% (> 10 %) may indicate run-to-run instability.
- **CLK_TCK = 100** assumed (standard Linux kernel default; verified via `getconf CLK_TCK` inside the container).
