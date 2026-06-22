# DS-rust — Phase 1 raw-power benchmark report

Run directory: `results/rawpower/rawpower-slow-1781886638-56350`

> **Headroom verdict key:**
> - `server_bound ✓` — server CPU was ≥ 90 % of its allocation; this is the trustworthy ceiling.
> - `⚠️ client_capped` — server still had headroom; the number is a lower bound, NOT DS's ceiling.
> - Median ± CV% shown where REPEATS = 3 (slow profile).

## 1. Reads — throughput by message size × connections

_ops/s = aggregate reads/s across all client pods. CPU% from sidecar samples.csv._

| cell | cpu_cores | size_bytes | conns | reads/s | CPU% (sidecar) | p99 ms | verdict |
|------|-----------|-----------|-------|---------|---------------|--------|---------|
| reads-cpu8-size1024-conn256 | 8 | 1,024 | 256 | 84,139 | 447.5% | 28.96 | ⚠️ client_capped |
| reads-cpu8-size16384-conn256 | 8 | 16,384 | 256 | 27,943 | 306.7% | 276.48 | ⚠️ client_capped |
| reads-cpu8-size262144-conn256 | 8 | 262,144 | 256 | 1,717 | 91.5% | 1360.89 | ⚠️ client_capped |

## 3. Appends — throughput by connections × body mode

_appends/s = aggregate appends/s. disk MB/s = server's actual /proc/io write_bytes rate (ground truth). CPU% from sidecar._

| cell | cpu_cores | conns | body_mode | appends/s | disk MB/s | CPU% (sidecar) | p99 ms | verdict |
|------|-----------|-------|-----------|----------|-----------|---------------|--------|---------|
| append-cpu8-conn256-binary-p1024 | 8 | 256 | binary-p1024 | 49,968 | 73 | 242.8% | 46.21 | ⚠️ client_capped |
| append-cpu8-conn256-binary-p1048576 | 8 | 256 | binary-p1048576 | 375 | 334 | 89.3% | 4112.38 | ⚠️ client_capped |
| append-cpu8-conn256-binary-p16384 | 8 | 256 | binary-p16384 | 18,160 | 288 | 139.6% | 112.00 | ⚠️ client_capped |
| append-cpu8-conn256-binary-p262144 | 8 | 256 | binary-p262144 | 1,435 | 337 | 84.3% | 1036.80 | ⚠️ client_capped |

## 6. Cold-tier read — replay from object store

_--tier local: reads go through the cold tier (simulated S3-on-NVMe). Seed = 100 MB to exceed hot cache._

| cell | cpu_cores | reads/s | throughput | CPU% (sidecar) | p99 ms | verdict |
|------|-----------|---------|------------|---------------|--------|---------|
| reads-cold-cpu8-size1m-conn64 | 8 | - | - | 10.2% | - | ⚠️ client_capped |

## 7. Single-stream fan-out — delivery latency vs subscriber count

_p99 = end-to-end delivery latency (writer → last subscriber). events/s = aggregate across all subscribers._

| cell | cpu_cores | subscribers | events/s | p50 ms | p99 ms | p999 ms | verdict |
|------|-----------|------------|---------|--------|--------|---------|---------|
| fanout-cpu8-subs2000 | 8 | 2000 | 122,278 | 70.91 | 339.45 | 1102.85 | ⚠️ client_capped |
| fanout-cpu8-subs10000 | 8 | 10000 | 100,398 | 522.75 | 3104.77 | 3936.26 | ⚠️ client_capped |
| fanout-cpu8-subs40000 | 8 | 40000 | - | - | - | - | ⚠️ client_capped |

## Headroom honesty summary

- **server_bound cells:** 0 — these reflect DS's true ceiling.
- **client_capped cells:** 11 — these are lower bounds; DS could do more.

### ⚠️ Client-capped cells (numbers are lower bounds)

| cell | reads/s or appends/s | CPU% | parallelism |
|------|---------------------|------|------------|
| append-cpu8-conn256-binary-p1024 | 49,968 | 242.8% | 4 |
| append-cpu8-conn256-binary-p1048576 | 375 | 89.3% | 4 |
| append-cpu8-conn256-binary-p16384 | 18,160 | 139.6% | 4 |
| append-cpu8-conn256-binary-p262144 | 1,435 | 84.3% | 4 |
| fanout-cpu8-subs10000 | - | 405.9% | 4 |
| fanout-cpu8-subs2000 | - | 428.0% | 4 |
| fanout-cpu8-subs40000 | - | 18.9% | 4 |
| reads-cold-cpu8-size1m-conn64 | - | 10.2% | 4 |
| reads-cpu8-size1024-conn256 | 84,139 | 447.5% | 4 |
| reads-cpu8-size16384-conn256 | 27,943 | 306.7% | 4 |
| reads-cpu8-size262144-conn256 | 1,717 | 91.5% | 4 |

## Disclosures

- **Object tier = in-cluster MinIO on local NVMe** — near-best-case for the cold tier (low latency, no cross-AZ hop); not representative of remote cloud S3. Absolute cold-tier numbers would be lower against real cloud S3.
- **Server CPU% from sidecar, not cgroup CPUUsageNSec** — the metrics sidecar polls `/proc/<pid>/stat` cpu_ticks at intervals; CPU% = Δcpu_ticks / CLK_TCK (100) / Δelapsed_s × 100. This is per-process wall-clock CPU%, not cgroup accounting.
- **server_bound = trustworthy ceiling** — the headroom guard bumps client parallelism until the server consumes ≥ 90 % of its CPU allocation. Only server_bound cells reflect DS's true throughput ceiling. client_capped cells ran out of client pods before saturating the server — those numbers are lower bounds.
- **Where we have server_bound numbers, they reflect DS's true ceiling** — which a 3-core-wrk single-client run could not reach.
- **Median + CV% for slow profile (REPEATS=3)** — per-cell median across 3 repeats; CV% = sample_stddev/mean × 100 (÷ N-1). High CV% (> 10 %) may indicate run-to-run instability.
- **CLK_TCK = 100** assumed (standard Linux kernel default; verified via `getconf CLK_TCK` inside the container).

