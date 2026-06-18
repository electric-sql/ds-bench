# Durable-streams benchmark suite — design

**Date:** 2026-06-18 · **Status:** design for review (supersedes the Track-1/Track-2
framing as the *organizing* doc; those specs become sub-parts) · **Repo:** `ds-rust-bench`

## Purpose (reframed)

Turn this repo into a **publishable, Kubernetes-native benchmark suite whose single
purpose is to evaluate a durable-streams-protocol server.** It produces **shareable
raw single-node numbers** for the Rust DS server first, and supports **pluggable
systems** (durable-streams-rust, durable-streams-node, ursula, S2 Lite, and others
people want to integrate) as comparison backends. Comparison is a feature, not the
focus — the focus is *measuring the DS server well*, reproducibly, on real hardware,
with results we can publish.

### Principles
- **One suite, one purpose.** Evaluate a DS server. Other systems are pluggable.
- **Kubernetes-native.** Reuse the proven fleet → coordinator → exact-HDR-merge
  harness on a fixed NVMe node; reproducible cluster bring-up/tear-down.
- **Pluggable + documented.** Adding a system = dropping in a `systems/<name>/`
  adapter that satisfies a documented contract. No core changes.
- **Publishable.** Clean structure, methodology doc, pinned/reproducible configs,
  run-history, and honest disclosures baked into every rendered report.
- **Honest by construction.** Single-node vs multi-node, disk substrate, per-system
  caveats stated in the output, not buried (carried from the findings work).

## Two measurement engines (the distinction that drove the structure)

| Engine | Scope | What it measures | Cross-system? |
|---|---|---|---|
| **`micro/` (autobench, ported from `durable-streams-bench`)** | DS-server **internals**, single box | engine {hyper/raw/uring}, CPU-core scaling, memory/cold isolation, splice append, tiering — `rps`, p50/p99/max, **CPU%**, MB/s | **No** — these knobs are DS-server-specific. This is the **DS-rust raw deep-dive**. |
| **`ds-bench/` (Rust protocol client)** | **protocol-level**, distributed | multi-stream write, SSE fan-out, catch-up replay, mixed, **cardinality (new)** — exact cross-fleet HDR-merged percentiles + throughput | **Yes** — runs against any system speaking the DS HTTP+SSE protocol. |

`micro/` answers "how fast is *this* server and which engine/knobs win"; `ds-bench/`
answers "how do systems compare at the protocol level, and where do they scale-wall."

## Repository structure (publishable layout)

```
ds-rust-bench/
├── systems/                      # one pluggable adapter per system (THE extension point)
│   ├── _CONTRACT.md              # how to add a system (the adapter contract, below)
│   ├── durable-streams-rust/     # Dockerfile|image, k8s Deployment template, api-style, config, capabilities
│   ├── durable-streams-node/
│   ├── ursula/                   # Helm/Deployment + values; preset; capabilities
│   ├── s2/                       # image, env; capabilities (write+fanout only)
│   └── <your-system>/
├── ds-bench/                     # protocol client: multi-stream, fan-out, catch-up, mixed, cardinality(NEW)
├── micro/                        # autobench: run.sh, lib.sh, studies/*, aggregate.py (ported)
├── deploy/                       # k8s harness: server templates, fleet Job, coordinator, MinIO, monitoring sidecar
├── scripts/                      # gke-up/down, run, matrix, cardinality, render, logrun
├── results/  bench-history/      # outputs + run-history (runlog.tsv)
└── docs/                         # methodology, how-to-publish, how-to-add-a-system, results
```

(Coupled but well-structured, per the directive. `micro/` and `ds-bench/` stay
distinct because they answer different questions; `systems/` is the single seam where
new backends plug in.)

## The pluggable-system contract (`systems/_CONTRACT.md`)

A system is measurable by the suite if its adapter provides:
1. **Image** — a built Dockerfile or a pullable image reference (amd64).
2. **Deploy template** — a k8s manifest (or Helm values) that runs it on the NVMe
   `role=server` node, mounts data on the NVMe `emptyDir`, and offloads to the shared
   in-cluster MinIO (matched durability config).
3. **Protocol mapping** — the `ds-bench --api-style` it speaks (`durable`/`ursula`/`s2`/…),
   or a new `ApiStyle` variant + its create/append/read/SSE mapping.
4. **Capabilities** — which workloads it supports (e.g. S2 = write + fan-out only;
   excluded from catch-up + mixed). The runner skips unsupported cells and the
   renderer prints `—` with the documented reason.
5. **Health + (ideally) metrics** — a readiness endpoint; and for the cardinality
   test, either a metrics/RSS endpoint or acceptance of a `/proc`-sampling sidecar.
6. **Disclosures** — a short `NOTES.md`: durability model, substrate, single/multi-node,
   anything that must appear in the report (honesty by construction).

## Test suite — tiers, and what is READY vs NEEDS IMPLEMENTATION

### Tier A — Raw single-node (`micro/`, DS-rust deep-dive) · **NEEDS IMPLEMENTATION**
The shareable raw numbers. Port `autobench/` in; run it in-cluster on a dedicated NVMe
node. Studies (from the survey): **engines** (hyper/raw/uring × read-size × conns),
**cpu_scaling** (2/4/6/8 cores), **memory_cold** (hot-under-cold eviction), **splice**
(binary append 64K/1M), **tiering** (local vs S3, cold reads).
- **Ready:** the autobench scripts exist (shell+wrk+python, machine-readable
  `results.jsonl` + `RESULTS.md` + `meta.txt`).
- **Needs:** (1) port `autobench/` into `micro/`; (2) a Dockerfile that builds the DS
  server + bundles `wrk`/`curl`/`python3`; (3) a **k8s Job that owns a dedicated NVMe
  node** (`nodeSelector` + full-node requests), `privileged` for `drop_caches`, on a
  node pre-set to the `performance` governor + CPU-manager static policy (so cgroup
  pinning is faithful) — **Option A** from the survey, preserving autobench's
  server+client-co-located isolation so numbers stay comparable to the existing
  Hetzner `RESULTS.md`; (4) results → MinIO/GCS → rendered into `results/`.
- **Note:** Tier A is DS-server-specific (engine/knob studies don't apply to
  ursula/S2). Cross-system comparison lives in Tier B.

### Tier B — Macro protocol workloads (`ds-bench`, cross-system) · **READY (cleanup needed)**
multi-stream / fan-out / catch-up / mixed against any pluggable system. This is built
and runs end-to-end (exact cross-node HDR merge proven).
- **Ready:** all four workloads, the fleet+coordinator+merge, `--api-style {durable|ursula|s2}`.
- **Needs:** (1) a **raw single-node renderer** (DS-rust alone, the shareable view —
  not just the comparison table); (2) **re-verify/drop the ursula fan-out 916 ms
  outlier** (suspected harness artifact); (3) the **clean ursula preset sweep** (the
  earlier one was corrupted by a concurrency bug — single-runner this time); (4) a
  DS-node adapter (the Node server) for `systems/durable-streams-node/`.

### Tier C — Parameter sweeps (`ds-bench`) · **PARTIAL**
- **Ready:** client-pod saturation sweep (2→4→8 demonstrated; DS-rust scales to ~200k w/s).
- **Needs:** automate **payload sweep** (100 B / 1 KB / 16 KB) and **subscriber sweep**
  (100 → 1k → 10k) as first-class matrix dimensions in the runner + renderer.

### Tier D — Cardinality / millions of streams (`ds-bench` cardinality workload) · **NEEDS IMPLEMENTATION**
The decisive scalability test. Full design below. Scope: **DS-rust + ursula** (show
each system's stream-count wall side by side; both were code-verified to hold
unbounded resident per-stream state, so this measures *where* each falls over).

---

## Tier D in detail — the millions-of-streams cardinality test

**Question it answers:** for a single server, how does **server memory (RSS) and
operation latency scale with the NUMBER of streams** (not data volume), and where is
the wall (OOM / 503 / latency cliff)? Plus **boot/recovery time vs stream count**
(both DS-rust and ursula load/replay per-stream state at startup → recovery scales
with N — a direct cardinality signal).

**Why `ds-bench`, not off-the-shelf (decided):** the hard parts are sharding a stream
**keyspace** across many client machines, **correlating client latency with server
RSS** at each cardinality level, and protocol fidelity — none of which k6/Locust give;
and we already own the k8s fleet+coordinator orchestration. We extend `ds-bench` with
a `cardinality` workload. (k6-operator remains a fallback for pure HTTP connection
scale, but we'd still hand-build keyspace + RSS correlation.)

**Design:**
- **Client fleet** — k8s Indexed Job, `parallelism = P` pods across a **scaled client
  node pool**; pod *i* owns stream slice `[i·S, (i+1)·S)`. (This is the "more client
  machines" coordination: size P and the node pool so `aggregate_create_rate ×
  duration ≥ N`.)
- **Phase 1 — populate:** each pod creates its `S` streams (one small append each)
  over a **bounded keepalive connection pool** — streams persist as *server state*, so
  no connection-per-stream is needed. Sweep total **N: 10k → 100k → 1M → 5M** (stop at
  the wall).
- **Phase 2 — probe (at each N plateau):** drive a light **sampled** append + catch-up
  workload over a random subset of streams; HDR-merge client p50/p99 across the fleet.
- **Server instrumentation (the key new piece):** a **monitoring sidecar** (or the
  system's metrics endpoint) samples **RSS, open fds, heap/GC** at intervals; the
  coordinator records **RSS-vs-N** and **p99-vs-N**. Also measure **boot/recovery time
  at each N** (restart the server with N streams resident; time to ready).
- **Failure capture:** record the onset of OOMKill / HTTP 503 (ursula's
  `ColdBackpressure` admission gate at 64 MiB/group is an expected early wall) /
  connection errors — i.e., *where* and *how* each system breaks.
- **Headline outputs:** (1) **server RSS vs stream count** (the cardinality wall);
  (2) **p99 vs stream count**; (3) **recovery time vs stream count**; (4) the break
  point per system. DS-rust vs ursula on the same axes.

**ds-bench work:** new `cardinality` mode (keyspace slice from `JOB_COMPLETION_INDEX`,
create-then-sample, configurable N/S/sample-rate); emit per-pod HDR + create-rate;
coordinator already merges. **deploy work:** the RSS/metrics sidecar + a
`scripts/gke-cardinality.sh` that drives the N-sweep, restarts for recovery timing,
and collects server metrics alongside the merged client HDR. **System contract:** each
system declares how to read its RSS (metrics endpoint or `/proc` via sidecar).

**Caveat to publish:** this needs the **client node pool scaled up** and is the most
resource-intensive run; it is gated behind explicit opt-in (cost), and DS-rust's wall
is expected to move only after the server-side eviction/lazy-load work the owner plans
(today both systems hold unbounded per-stream state — see the findings doc).

---

## Publishability requirements
- **Top-level `README`:** what the suite measures, the two engines, how to run (kind
  for mechanics, GKE for numbers), how to read results, and the honesty/disclosure
  section.
- **`systems/_CONTRACT.md` + `docs/adding-a-system.md`:** the adapter contract +
  a worked example, so external systems can be added.
- **Reproducibility:** pinned images + commits, committed configs, `meta.txt`-style
  run metadata (host/kernel/cpu/governor/commit), and `bench-history/runlog.tsv`.
- **Honest reports:** every rendered report carries the per-system disclosures
  (single/multi-node, disk substrate, capability exclusions) — not optional.

## What the owner's server work should target (system contract, DS-rust)
To be fully measurable by the suite, the DS server should expose:
- a **readiness** endpoint (have), and a **metrics/RSS endpoint** (for Tier D) so the
  cardinality monitor doesn't depend on a `/proc` sidecar;
- the **`uring` engine** built/enabled on the Linux NVMe node (for Tier A's engine study);
- (for a real "millions of streams" claim) **lazy stream-state load + LRU/idle-eviction
  + producer-state TTL** — Tier D is the test that would then prove the bound moved.

## Open items (resolve in the implementation plan)
1. Tier A in-cluster isolation: confirm Option A (dedicated NVMe node, privileged Job,
   pre-set governor) vs Option B (server Deployment + remote-targeting wrk client).
2. RSS monitoring mechanism per system: metrics endpoint vs `/proc` sidecar vs
   kubelet/cAdvisor — and whether to (finally) add kube-prometheus-stack on GKE.
3. DS-node server adapter: build/run of the Node server in `systems/`.
4. Cardinality client-fleet sizing + node-pool scale to hit 1M–5M streams in bounded time.
5. Whether ursula cardinality runs use its (off-by-default) cold tier or hot-only.

## Success criteria
- `micro/` (Tier A) runs in-cluster and emits shareable DS-rust raw numbers comparable
  to the existing `RESULTS.md` methodology.
- `ds-bench` (Tier B/C) renders a clean **DS-rust raw single-node** report + the
  cross-system comparison, with the fan-out outlier resolved and a clean preset sweep.
- Tier D produces **RSS / p99 / recovery vs stream-count** curves for DS-rust + ursula
  and locates each wall.
- A new system can be added via `systems/<name>/` without core changes, and the suite
  is documented well enough to publish.
