# Benchmark suite — current state & test matrix

**As of 2026-06-18.** Honest inventory: what has actually RUN (we have numbers), what
is BUILT but not yet run, and what is PLANNED but not built. See also the design spec
(`docs/superpowers/specs/2026-06-18-benchmark-suite-design.md`) and findings
(`docs/benchmark-findings.md`).

## Two measurement tools

| Tool | Decoupled & scalable clients? | Use |
|---|---|---|
| **`ds-bench` fleet** (k8s Indexed Job on a separate `role=client` pool) | **YES** — N pods, scaled independently until the *server* saturates (proven 2→8 pods → 200k w/s) | cross-system protocol throughput / saturation / fan-out / catch-up / (planned) cardinality |
| **`micro/`** (autobench port, co-located `wrk`) | **NO** — `wrk` shares the server node; throughput is client-bound (confirmed this run) | single-server raw efficiency: read rps/latency, cpu-scaling, splice, (deferred) tiering/cold |

→ **Throughput numbers come from the fleet** (immune to the load-generator cap). `micro/`
is for server-side efficiency where co-location is intended; its throughput is a floor.

---

## A. HAVE RUN — real numbers exist

### A1. DS-rust raw single-node (`micro/`, GKE n2d-standard-8 / EPYC 7B13, single-engine raw, `durable-streams bf19bb72`)
| study | result | trustworthy? |
|---|---|---|
| read 1 KiB / 16 KiB / 1 MiB (read-size × connections) | 146,460 / 97,622 / 5,684 rps; p99 6.47 / 6.74 / 52.65 ms | **latency yes; throughput is `wrk`(2-core)-CAPPED → a floor** |
| append 100 B | 120,950 rps; scales 86k→117k across 2→8 cores | yes (server-bound) |
| splice (1 MiB binary append) | throughput flat ~392 rps; CPU 70%→45% with splice on | yes (splice = CPU saving) |
| cpu_scaling (raw, 2/4/6/8 cores) | append scales; read non-monotonic (client cap) | append yes; read = floor |
_Studies run: `engines cpu_scaling splice`. `memory_cold` + `tiering` were NOT run (see B)._

### A2. Cross-system macro (`ds-bench` fleet, single-node, MinIO-on-NVMe tier)
| workload | DS-rust | ursula (preset standard) | S2 Lite |
|---|---|---|---|
| multi-stream write w/s · p99 | **78,490 · 24 ms** | 7,611 · 309 ms | 15,323 · 72 ms |
| fan-out events/s · p99 | **119,984 · 47 ms** | 44,791 · **916 ms ⚠️** | 84,920 · 63 ms |
| catch-up MB/s · p99 | 786 · 7.5 ms | 988 · 59 ms | — (excluded) |
| saturation (DS-rust write, pods 2→4→8) | 84k → 181k → **200k** w/s | — | — |
_⚠️ ursula fan-out 916 ms is suspected a harness artifact — NOT yet re-verified (see B)._
_mixed workload also ran for DS-rust + ursula (per-class latencies in findings doc)._

---

## B. BUILT, NOT YET RUN (ready — needs a cluster session)

- **Clean ursula preset sweep** (`scripts/gke-ursula-sweep.sh`) — sole-mutator, sequential.
  Built + reviewed; the earlier sweep was discarded (concurrency-corrupted). **Not run.**
- **ursula fan-out 916 ms diagnostic** (`docs/fan-out-outlier-diagnostic.md`) — procedure
  written; **not executed** (confirm/refute the outlier).
- **`micro/` other profiles/studies:** `memory_cold` (needs cgroup-delegation in-cluster)
  and `tiering` (needs the `--features tier` server binary + GCS-S3-compat verification) —
  both currently **self-skip**; the `full` profile (vs `fast`) not run.
- **`render-raw.py`** — built + verified against existing data (the DS-rust raw report).

---

## C. PLANNED, NOT BUILT

- **`sustained` workload (decided 2026-06-18):** steady offered load held for a long
  duration while **sweeping stream count** (10 → 100 → 1k → 10k); reports throughput +
  **latency stability over time** + **server RSS drift**. Answers "sustained load at
  different stream counts." Fleet workload; needs the metrics sidecar. **Not built.**
- **Multi-stream fan-out (decided 2026-06-18):** extend `fan-out` to **M streams × S
  subscribers each** (concurrent) — realistic many-stream SSE fan-out vs today's single
  hot stream. **Not built.**
- **Micro rescope (decided 2026-06-18):** `micro/` is now efficiency-only (CPU-per-op,
  splice CPU, syscalls, memory-cold; co-located). The **read-rps + cpu-scaling-rps
  throughput studies relocate to the fleet** (they were `wrk`-capped co-located). Fleet
  side of that relocation **not built**.
- **Tier C — parameter sweeps:** payload **100 B / 1 KB / 16 KB** (writes) and **subscribers
  100 → 1k → 10k** (fan-out) as first-class swept dimensions in the runner + renderer.
  _(Today's runs used single fixed values, not sweeps.)_
- **Tier D — cardinality / millions of streams (the big one):** scale stream COUNT
  (10k → 100k → 1M → 5M) on the write (create) AND read paths; measure **server RSS, p99,
  and boot/recovery time vs stream count**, and locate each system's wall (DS-rust + ursula).
  Needs: a `ds-bench` `cardinality` workload (keyspace-sharded across the fleet) + a
  server-metrics sidecar. **Designed (spec §Tier D); not built.** This is the experiment
  that actually answers "scale the number of streams."
- **Fleet-driven micro workloads:** move the throughput micro-studies (read-size, append,
  splice) onto the scalable fleet so they're not `wrk`-capped — per the load-generation
  decision. Needs the micro-patterns added to `ds-bench`. **Not built.**
- **Server-metrics sidecar** (CPU% + RSS), shared by fleet-micro + cardinality. **Not built.**
- **Client-headroom guardrail:** auto-flag/invalidate a throughput number when the load
  generator saturates. **Not built.**
- **`systems/` pluggable-adapter restructure** (publishable; one dir per system + contract).
  **Not built.**
- **DS-node adapter:** the Node/TS durable-streams server. Currently **SKIPPED** — it's a
  library with no runnable entrypoint / S3 cold tier (`gke/ds-node-SKIPPED.md`).
- **Multi-node (Phase 3):** ursula 3/5-node scale-out + DS-rust multi-node → true
  3v3/5v5; deferred until DS-rust has multi-node.

---

## Direct answers to the three standing concerns
1. **Scale clients without a generation bottleneck** → YES via the `ds-bench` fleet
   (decoupled, horizontally scalable, proven). `micro/` co-located is client-capped (by
   design, scoped to efficiency). Client-headroom auto-guardrail = planned (C).
2. **Scale stream count, read + write** → multi-stream (write, N streams) and catch-up
   (read, N streams) EXIST and have run, at FIXED counts. A deliberate stream-count sweep
   and high-cardinality (millions) = **Tier D, planned, not built** (C).
3. **SSE fan-out** → EXISTS and RAN (DS-rust 119,984 events/s, p99 47 ms). Subscriber-count
   sweep = Tier C, planned (C). ursula fan-out outlier = built diagnostic, not run (B).
