# autobench — autonomous, reproducible benchmark suite

A single-command harness that measures the Durable Streams Rust server's
single (raw) durable-streams engine under **controlled CPU and memory allocation**,
so the numbers are reproducible and reliable (not artifacts of the load
generator stealing the server's cores).

## Why this exists / methodology

Running `wrk` on the same box as the server makes client and server fight for
cores, which can hide performance characteristics. autobench isolates them:

- **Server isolation** — the server runs as a *transient systemd service* with a
  dedicated cgroup: `AllowedCPUs` pins it to a core set and `MemoryMax` bounds its
  page cache. Server CPU is read exactly from the cgroup (`CPUUsageNSec`), not
  estimated.
- **Client isolation** — `wrk` is `taskset`-pinned to a **disjoint** core set, so
  client and server never contend.
- **Bounded memory → real cold I/O** — on a high-RAM box a "cold" stream just
  stays in page cache. Capping the server cgroup's memory below the stream size
  forces genuine disk reads, which is the only way to measure cold-read isolation
  and the `--read-offload` modes meaningfully.
- **Stable clocks** — sets the CPU governor to `performance` before measuring.
- **Repeats + variance** — every cell runs `REPEATS` times; results report the
  median and the throughput coefficient of variation (cv%).

## Requirements (Linux)

`cargo`, `wrk`, `python3`, `curl`, `sudo` (for `systemd-run`, cgroup limits,
governor, `drop_caches`), and a cgroup-v2 + systemd host. Tested on Ubuntu 24.04 /
kernel 6.8.

## Run

```bash
export SR_DIR=/path/to/packages/server-rust
cd "$SR_DIR/bench/autobench"

PROFILE=smoke bash run.sh          # ~5 min, validates the whole pipeline
bash run.sh                        # full matrix (config.env)
STUDIES=engines DUR=15 bash run.sh # one study, longer windows
```

Output lands in `out/<timestamp>/`: `results.jsonl` (one JSON object per cell),
`meta.txt` (environment), `RESULTS.md` (aggregated tables), `run.log`.

## Studies (`config.env` controls the matrix)

| study | varies | answers |
|-------|--------|---------|
| `engines` | read-size {1K, 16K, 1M} × concurrency {16, 64, 256, 1024}, + `--read-offload` modes | raw server throughput/latency/CPU at various I/O loads and request patterns |
| `cpu_scaling` | server cpuset {2,4,6,8 cores} | how the raw server scales with cores; where it plateaus |
| `memory_cold` | `MemoryMax` {∞,2G,1G,512M} × `--read-offload` mode {inline, tail, always} | cold-read isolation with *real* disk faults; `inline` stall vs `tail`/`always` offload |
| `splice` | binary append, `--splice-appends` off/on | the zero-copy-append CPU lever |
| `tiering` | `--tier local`(+`s3`) | sealing/offload append cost; cold-tier read throughput |

Key knobs (all overridable inline): `SERVER_CPUS`, `CLIENT_CPUS`, `DUR`,
`REPEATS`, `READ_SIZES`, `CONNS_SWEEP`, `SCALE_CPUSETS`, `COLD_MEMS`,
`COLD_STREAM_GIB`, `TIER_SEG_BYTES`, `TIER_S3` (+`TIER_S3_ENDPOINT/BUCKET/KEY/SECRET`).

## Interpreting results

- **engines/read_size**: small sizes (≤16 KB) are served from the in-memory tail
  cache (`Body::Full`) — they measure the socket-send path; 1 MB is a file read
  (`sendfile` on the raw server).
- **rps_cv%** > ~5% means a noisy cell — re-run or investigate before trusting it.
- **memory_cold**: at `MemoryMax=∞` all modes look alike (no disk I/O); the
  isolation story appears only as the cap drops below the cold stream size.

## Safety

The server always runs in a named transient unit and `wrk`/background readers are
tracked by PID + mopped up by URL, with an `EXIT`/`INT`/`TERM` trap reaper — the
harness cannot leave runaway load behind (an earlier ad-hoc harness could, which
spiked the host). `out/` is gitignored.
