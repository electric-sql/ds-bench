# DS-rust combined report — remote/GKE (europe-west1-d, n2d-standard-8)
- server d39ad487 (streams-rust) · NOFILE=1048576 · fd-fix confirmed
- profile: slow, MAX_BUMPS=3, REPEATS=1

# DS-rust — Phase 1 raw-power benchmark report

Run directory: `results/rawpower/rawpower-slow-1781857852-90138`

> **Headroom verdict key:**
> - `server_bound ✓` — server CPU was ≥ 90 % of its allocation; this is the trustworthy ceiling.
> - `⚠️ client_capped` — server still had headroom; the number is a lower bound, NOT DS's ceiling.
> - Median ± CV% shown where REPEATS = 3 (slow profile).

## 1. Reads — throughput by message size × connections

_ops/s = aggregate reads/s across all client pods. CPU% from sidecar samples.csv._

| cell | cpu_cores | size_bytes | conns | reads/s | CPU% (sidecar) | p99 ms | verdict |
|------|-----------|-----------|-------|---------|---------------|--------|---------|
| reads-cpu2-size1024-conn16 | 2 | 1,024 | 16 | 20,677 | 144.6% | 82.37 | ⚠️ client_capped |
| reads-cpu2-size1024-conn64 | 2 | 1,024 | 64 | 22,933 | 148.0% | 183.68 | ⚠️ client_capped |
| reads-cpu2-size1024-conn256 | 2 | 1,024 | 256 | 20,646 | 155.8% | 596.99 | ⚠️ client_capped |
| reads-cpu2-size16384-conn16 | 2 | 16,384 | 16 | 2,132 | 41.7% | 2555.90 | ⚠️ client_capped |
| reads-cpu2-size16384-conn64 | 2 | 16,384 | 64 | 2,127 | 43.7% | 7512.06 | ⚠️ client_capped |
| reads-cpu2-size16384-conn256 | 2 | 16,384 | 256 | 2,317 | 56.6% | 5324.80 | ⚠️ client_capped |
| reads-cpu4-size1024-conn16 | 4 | 1,024 | 16 | 32,945 | 293.4% | 55.04 | ⚠️ client_capped |
| reads-cpu4-size1024-conn64 | 4 | 1,024 | 64 | 33,064 | 271.9% | 375.81 | ⚠️ client_capped |
| reads-cpu4-size1024-conn256 | 4 | 1,024 | 256 | 33,586 | 282.0% | 488.70 | ⚠️ client_capped |
| reads-cpu4-size16384-conn16 | 4 | 16,384 | 16 | 2,174 | 49.0% | 1856.51 | ⚠️ client_capped |
| reads-cpu4-size16384-conn64 | 4 | 16,384 | 64 | 2,198 | 50.6% | 7983.10 | ⚠️ client_capped |
| reads-cpu4-size16384-conn256 | 4 | 16,384 | 256 | 2,410 | 69.3% | 5382.14 | ⚠️ client_capped |
| reads-cpu8-size1024-conn16 | 8 | 1,024 | 16 | 34,898 | 315.6% | 61.25 | ⚠️ client_capped |
| reads-cpu8-size1024-conn64 | 8 | 1,024 | 64 | 33,399 | 348.5% | 412.16 | ⚠️ client_capped |
| reads-cpu8-size1024-conn256 | 8 | 1,024 | 256 | 35,728 | 285.1% | 716.29 | ⚠️ client_capped |
| reads-cpu8-size16384-conn16 | 8 | 16,384 | 16 | 2,143 | 39.8% | 1589.25 | ⚠️ client_capped |
| reads-cpu8-size16384-conn64 | 8 | 16,384 | 64 | 2,173 | 47.4% | 8237.06 | ⚠️ client_capped |
| reads-cpu8-size16384-conn256 | 8 | 16,384 | 256 | 2,572 | 66.9% | 5373.95 | ⚠️ client_capped |

## 2. Read scaling by server cores

_reads/s and CPU% per server core budget (same size×conn point). Efficiency = reads/s per core._

### size=1,024 B, conn=16

| cpu_cores | reads/s | CPU% | efficiency (reads/s/core) | verdict |
|-----------|---------|------|--------------------------|---------|
| 2 | 20,677 | 144.6% | 10,338 | ⚠️ client_capped |
| 4 | 32,945 | 293.4% | 8,236 | ⚠️ client_capped |
| 8 | 34,898 | 315.6% | 4,362 | ⚠️ client_capped |

### size=1,024 B, conn=64

| cpu_cores | reads/s | CPU% | efficiency (reads/s/core) | verdict |
|-----------|---------|------|--------------------------|---------|
| 2 | 22,933 | 148.0% | 11,466 | ⚠️ client_capped |
| 4 | 33,064 | 271.9% | 8,266 | ⚠️ client_capped |
| 8 | 33,399 | 348.5% | 4,175 | ⚠️ client_capped |

### size=1,024 B, conn=256

| cpu_cores | reads/s | CPU% | efficiency (reads/s/core) | verdict |
|-----------|---------|------|--------------------------|---------|
| 2 | 20,646 | 155.8% | 10,323 | ⚠️ client_capped |
| 4 | 33,586 | 282.0% | 8,397 | ⚠️ client_capped |
| 8 | 35,728 | 285.1% | 4,466 | ⚠️ client_capped |

### size=16,384 B, conn=16

| cpu_cores | reads/s | CPU% | efficiency (reads/s/core) | verdict |
|-----------|---------|------|--------------------------|---------|
| 2 | 2,132 | 41.7% | 1,066 | ⚠️ client_capped |
| 4 | 2,174 | 49.0% | 543 | ⚠️ client_capped |
| 8 | 2,143 | 39.8% | 268 | ⚠️ client_capped |

### size=16,384 B, conn=64

| cpu_cores | reads/s | CPU% | efficiency (reads/s/core) | verdict |
|-----------|---------|------|--------------------------|---------|
| 2 | 2,127 | 43.7% | 1,063 | ⚠️ client_capped |
| 4 | 2,198 | 50.6% | 550 | ⚠️ client_capped |
| 8 | 2,173 | 47.4% | 272 | ⚠️ client_capped |

### size=16,384 B, conn=256

| cpu_cores | reads/s | CPU% | efficiency (reads/s/core) | verdict |
|-----------|---------|------|--------------------------|---------|
| 2 | 2,317 | 56.6% | 1,159 | ⚠️ client_capped |
| 4 | 2,410 | 69.3% | 602 | ⚠️ client_capped |
| 8 | 2,572 | 66.9% | 322 | ⚠️ client_capped |

## 3. Appends — throughput by connections × body mode

_appends/s = aggregate appends/s. CPU% from sidecar. 256-byte payload._

| cell | cpu_cores | conns | body_mode | appends/s | CPU% (sidecar) | p99 ms | verdict |
|------|-----------|-------|-----------|----------|---------------|--------|---------|
| append-cpu2-conn64-binary-p1024 | 2 | 64 | binary-p1024 | 58,090 | 139.5% | 62.02 | ⚠️ client_capped |
| append-cpu2-conn64-binary-p16384 | 2 | 64 | binary-p16384 | 33,564 | 148.9% | 109.44 | ⚠️ client_capped |
| append-cpu2-conn256-binary-p1024 | 2 | 256 | binary-p1024 | 51,048 | 141.8% | 215.55 | ⚠️ client_capped |
| append-cpu2-conn256-binary-p16384 | 2 | 256 | binary-p16384 | 32,243 | 156.5% | 421.38 | ⚠️ client_capped |
| append-cpu4-conn64-binary-p1024 | 4 | 64 | binary-p1024 | 48,708 | 217.4% | 72.25 | ⚠️ client_capped |
| append-cpu4-conn64-binary-p16384 | 4 | 64 | binary-p16384 | 32,132 | 209.2% | 107.65 | ⚠️ client_capped |
| append-cpu4-conn256-binary-p1024 | 4 | 256 | binary-p1024 | 45,428 | 205.3% | 235.78 | ⚠️ client_capped |
| append-cpu4-conn256-binary-p16384 | 4 | 256 | binary-p16384 | 34,316 | 202.6% | 396.54 | ⚠️ client_capped |
| append-cpu8-conn64-binary-p1024 | 8 | 64 | binary-p1024 | 49,103 | 221.5% | 71.17 | ⚠️ client_capped |
| append-cpu8-conn256-binary-p1024 | 8 | 256 | binary-p1024 | 45,874 | 216.0% | 121.22 | - |

## 5. Splice — 1 MB binary appends with/without --splice-appends

_CPU lever: splice should reduce kernel copy overhead for large payloads._

| cell | cpu_cores | conns | appends/s | throughput | CPU% (sidecar) | p99 ms | verdict |
|------|-----------|-------|----------|------------|---------------|--------|---------|
| append-splice-cpu2-conn256-binary-1m | 2 | 256 | 0 | - | 2.4% | 0.00 | ⚠️ client_capped |
| append-splice-cpu4-conn256-binary-1m | 4 | 256 | 0 | - | 2.7% | 0.00 | ⚠️ client_capped |

## 6. Cold-tier read — replay from object store

_--tier local: reads go through the cold tier (simulated S3-on-NVMe). Seed = 100 MB to exceed hot cache._

| cell | cpu_cores | reads/s | throughput | CPU% (sidecar) | p99 ms | verdict |
|------|-----------|---------|------------|---------------|--------|---------|
| reads-cold-cpu2-size1m-conn64 | 2 | - | - | 14.7% | - | ⚠️ client_capped |
| reads-cold-cpu4-size1m-conn64 | 4 | - | - | 27.6% | - | ⚠️ client_capped |

## 7. Single-stream fan-out — delivery latency vs subscriber count

_p99 = end-to-end delivery latency (writer → last subscriber). events/s = aggregate across all subscribers._

| cell | cpu_cores | subscribers | events/s | p50 ms | p99 ms | p999 ms | verdict |
|------|-----------|------------|---------|--------|--------|---------|---------|
| fanout-cpu2-subs1 | 2 | 1 | 40,880 | 0.53 | 1.40 | 5.75 | ⚠️ client_capped |
| fanout-cpu2-subs10 | 2 | 10 | 48,983 | 35.04 | 124.09 | 127.55 | ⚠️ client_capped |
| fanout-cpu2-subs100 | 2 | 100 | 27,723 | 205.44 | 336.89 | 416.25 | ⚠️ client_capped |
| fanout-cpu4-subs1 | 4 | 1 | 39,435 | 0.50 | 1.04 | 2.71 | ⚠️ client_capped |
| fanout-cpu4-subs10 | 4 | 10 | 121,649 | 55.90 | 62.75 | 71.10 | ⚠️ client_capped |
| fanout-cpu4-subs100 | 4 | 100 | 50,187 | 120.70 | 194.69 | 246.14 | ⚠️ client_capped |

## Headroom honesty summary

- **server_bound cells:** 0 — these reflect DS's true ceiling.
- **client_capped cells:** 37 — these are lower bounds; DS could do more.

### ⚠️ Client-capped cells (numbers are lower bounds)

| cell | reads/s or appends/s | CPU% | parallelism |
|------|---------------------|------|------------|
| append-cpu2-conn256-binary-p1024 | 51,048 | 141.8% | 32 |
| append-cpu2-conn256-binary-p16384 | 32,243 | 156.5% | 32 |
| append-cpu2-conn64-binary-p1024 | 58,090 | 139.5% | 32 |
| append-cpu2-conn64-binary-p16384 | 33,564 | 148.9% | 32 |
| append-cpu4-conn256-binary-p1024 | 45,428 | 205.3% | 32 |
| append-cpu4-conn256-binary-p16384 | 34,316 | 202.6% | 32 |
| append-cpu4-conn64-binary-p1024 | 48,708 | 217.4% | 32 |
| append-cpu4-conn64-binary-p16384 | 32,132 | 209.2% | 32 |
| append-cpu8-conn64-binary-p1024 | 49,103 | 221.5% | 32 |
| append-splice-cpu2-conn256-binary-1m | 0 | 2.4% | 32 |
| append-splice-cpu4-conn256-binary-1m | 0 | 2.7% | 32 |
| fanout-cpu2-subs1 | - | 72.7% | 32 |
| fanout-cpu2-subs10 | - | 142.9% | 32 |
| fanout-cpu2-subs100 | - | 143.4% | 32 |
| fanout-cpu4-subs1 | - | 84.1% | 32 |
| fanout-cpu4-subs10 | - | 274.9% | 32 |
| fanout-cpu4-subs100 | - | 277.7% | 32 |
| reads-cold-cpu2-size1m-conn64 | - | 14.7% | 32 |
| reads-cold-cpu4-size1m-conn64 | - | 27.6% | 32 |
| reads-cpu2-size1024-conn16 | 20,677 | 144.6% | 32 |
| reads-cpu2-size1024-conn256 | 20,646 | 155.8% | 32 |
| reads-cpu2-size1024-conn64 | 22,933 | 148.0% | 32 |
| reads-cpu2-size16384-conn16 | 2,132 | 41.7% | 32 |
| reads-cpu2-size16384-conn256 | 2,317 | 56.6% | 32 |
| reads-cpu2-size16384-conn64 | 2,127 | 43.7% | 32 |
| reads-cpu4-size1024-conn16 | 32,945 | 293.4% | 32 |
| reads-cpu4-size1024-conn256 | 33,586 | 282.0% | 32 |
| reads-cpu4-size1024-conn64 | 33,064 | 271.9% | 32 |
| reads-cpu4-size16384-conn16 | 2,174 | 49.0% | 32 |
| reads-cpu4-size16384-conn256 | 2,410 | 69.3% | 32 |
| reads-cpu4-size16384-conn64 | 2,198 | 50.6% | 32 |
| reads-cpu8-size1024-conn16 | 34,898 | 315.6% | 32 |
| reads-cpu8-size1024-conn256 | 35,728 | 285.1% | 32 |
| reads-cpu8-size1024-conn64 | 33,399 | 348.5% | 32 |
| reads-cpu8-size16384-conn16 | 2,143 | 39.8% | 32 |
| reads-cpu8-size16384-conn256 | 2,572 | 66.9% | 32 |
| reads-cpu8-size16384-conn64 | 2,173 | 47.4% | 32 |

## Disclosures

- **Object tier = in-cluster MinIO on local NVMe** — near-best-case for the cold tier (low latency, no cross-AZ hop); not representative of remote cloud S3. Absolute cold-tier numbers would be lower against real cloud S3.
- **Server CPU% from sidecar, not cgroup CPUUsageNSec** — the metrics sidecar polls `/proc/<pid>/stat` cpu_ticks at intervals; CPU% = Δcpu_ticks / CLK_TCK (100) / Δelapsed_s × 100. This is per-process wall-clock CPU%, not cgroup accounting.
- **server_bound = trustworthy ceiling** — the headroom guard bumps client parallelism until the server consumes ≥ 90 % of its CPU allocation. Only server_bound cells reflect DS's true throughput ceiling. client_capped cells ran out of client pods before saturating the server — those numbers are lower bounds.
- **Where we have server_bound numbers, they reflect DS's true ceiling** — which a 3-core-wrk single-client run could not reach.
- **Median + CV% for slow profile (REPEATS=3)** — per-cell median across 3 repeats; CV% = sample_stddev/mean × 100 (÷ N-1). High CV% (> 10 %) may indicate run-to-run instability.
- **CLK_TCK = 100** assumed (standard Linux kernel default; verified via `getconf CLK_TCK` inside the container).

# DS-rust — Phase 2 scale-out benchmark report

Run directory: `results/scaleout/scaleout-slow-1781868381-7895`

> **Headroom verdict key:**
> - `server_bound ✓` — server CPU was ≥ 90 % of its allocation; this is the trustworthy ceiling.
> - `⚠️ client_capped` — server still had headroom; the number is a lower bound, NOT DS's ceiling.
> - Median ± CV% shown where REPEATS ≥ 3.

## Headroom honesty summary

- **server_bound cells:** 0 — these reflect DS's true ceiling.
- **client_capped cells:** 0 — these are lower bounds; DS could do more.

## Disclosures

- **Single-node deployment** — DS-rust server runs as a single pod on a GKE node. These numbers reflect single-node concurrent-stream capacity; multi-node distribution is deferred to Phase 3.
- **Modern NVMe storage** — the object tier is in-cluster MinIO on local NVMe (near-best-case; not representative of remote cloud S3). Cold-tier absolute numbers would be lower against real cloud S3.
- **Fleet load generator** — writer pods are a decoupled client fleet; aggregate throughput sums each pod's headline figure. Sidecar samples RSS/CPU at intervals independently of the HDR merge window.
- **Server CPU% from sidecar** — `/proc/<pid>/stat` cpu_ticks polled at intervals; CPU% = Δcpu_ticks / CLK_TCK (100) / Δelapsed_s × 100. Per-process wall-clock CPU%, not cgroup accounting.
- **server_bound = trustworthy ceiling** — the headroom guard bumps client parallelism until server CPU ≥ 90 % of its allocation. Only `server_bound ✓` cells reflect DS's true scale-out ceiling. `⚠️ client_capped` cells are lower bounds.
- **Median + CV% for slow profile (REPEATS ≥ 3)** — per-cell median across repeats; CV% = sample_stddev/mean × 100 (÷ N-1). High CV% (> 10 %) may indicate run-to-run instability.
- **CLK_TCK = 100** assumed (standard Linux kernel default).

# DS-rust — sustained-stream benchmark report

Run directory: `results/sustained/sustained-1781853058-82697`

## 1. Throughput + tail latency vs stream count

| streams | aggregate_ops_per_sec | p50 ms | p99 ms | p999 ms | merged_samples |
|---|---|---|---|---|---|
| 10 | 199 | 1.84 | 10.74 | 37.44 | 17,940 |
| 50 | 996 | 2.91 | 15.51 | 24.08 | 89,700 |

## 2. Server memory vs stream count (RSS drift)

_RSS values in MiB. Slope = (rss\_end − rss\_start) / elapsed minutes._

| streams | rss_start_mib | rss_max_mib | rss_end_mib | rss_slope_mib_per_min |
|---|---|---|---|---|
| 10 | 4.4 | 6.9 | 6.9 | +1.501 |
| 50 | 7.4 | 10.9 | 10.9 | +2.201 |

## 3. CPU over time (steady-state check)

_CPU% derived from consecutive cpu\_ticks deltas ÷ CLK\_TCK (100) ÷ elapsed seconds × 100._
_Flat = stddev < max(10 pp, 15 % of mean)._

- **10 streams**: mean CPU 6.4% — flat (steady)
- **50 streams**: mean CPU 25.6% — flat (steady)

## Disclosures

- **Single-node deployment** — DS-rust server runs as a single pod on a GKE node. These numbers reflect single-node sustained capacity only; multi-node scale-out is deferred to Phase 3.
- **Load generated by the decoupled client fleet** — writer pods run independently of the server metrics sidecar; sidecar samples RSS/CPU at intervals and is not synchronised to the HDR merge window.
- **Object/metrics caveats** — the object tier is in-cluster MinIO on local NVMe (near-best-case; not representative of remote cloud S3). Latencies are HDR-merged across all client-fleet pods; throughput sums each pod's headline figure.
- **Per-pod latency-over-time snapshots are NOT yet collected** — the sidecar provides server RSS and CPU over time; the `sustained --snapshot-secs` per-pod latency time-series would require pod-log collection from every client pod. This is a follow-up item.
- **RSS slope** is computed as a simple linear approximation: (rss\_end − rss\_start) / elapsed minutes. A positive slope indicates memory growth over the run; a near-zero slope indicates stable cardinality.
- **CPU% computation** assumes `CLK_TCK = 100` (standard Linux). Each interval's CPU% is (Δcpu\_ticks / 100) / elapsed\_s × 100. The stability flag is a heuristic (stddev < max(10 pp, 15 % of mean)).

