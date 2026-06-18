# Scale-out experiment: distributed clients vs DS, ursula & S2 on Kubernetes

**Date:** 2026-06-18 (refreshed from 2026-06-17)
**Status:** Refreshed design, pending implementation plan
**Repo:** `ds-rust-bench`
**Track:** 2 of 2 — scale-out experiment. Builds on
[Track 1: single-node comparison](2026-06-17-single-node-bench-design.md) (merged):
`ds-bench` (verbatim ursula-bench fork + our `catch_up.rs`), the durable backend
mapping, the matched-durability configs, and the S2 Lite integration.

## Purpose

Run a distributed-client benchmark of Durable Streams servers on Kubernetes, for
**competitive positioning**. The new capability over Track 1 is a **fleet of
`ds-bench` client pods** that can drive each system to its true **saturation
ceiling** — something a single client process on one machine cannot reach — plus
**ursula's server scale-out curve** (1 → 3 → 5 nodes), the one system here with
multi-node support.

## Systems under test

| System | Topology | Workloads | Notes |
| --- | --- | --- | --- |
| durable-streams (Rust) | single node (raw-only engine after the single-engine refactor); **multi-node when it lands → Phase 3** | all four | the system being positioned |
| durable-streams (Node/TS) | single node | all four | our own baseline + protocol-portability proof; expected far slower (~20–250×) |
| ursula | **1, 3, 5 nodes** (multi-Raft, Helm chart) | all four | competitor's scale-out story is its whole pitch |
| S2 Lite | single node (SlateDB → object-store write-through) | **write + fan-out only** | excluded from catch-up **and** mixed — both involve the catch-up read, which for S2 is a paginated, JSON/base64-enveloped `seq_num` read not comparable to the DS-protocol full-replay loop (see Track 1) |

## Locked decisions

| Decision | Choice |
| --- | --- |
| Goal | Competitive positioning (strict fairness + reproducibility) |
| Environment | **Local kind first (mechanics), then GKE (real numbers)** — see Phasing |
| Workload client | **`ds-bench`** (from Track 1), extended here with cross-pod HDR merge + the `mixed` workload; containerized, fanned out across client pods |
| First-run systems | DS-rust(1), DS-node(1), ursula(1/3/5), S2 Lite(1) |
| First-run workloads | write-throughput, SSE fan-out, catch-up (built), **mixed (to build)** |
| Durability alignment | Matched durable-to-disk + object-store offload (Track 1); S2's write-through substrate disclosed |
| Object store | MinIO in-cluster (portable across kind + GKE); swappable for cloud S3 on GKE |
| Observability | Merged HDR = authoritative source of truth everywhere; Prometheus + Grafana **only on GKE** (kube-prometheus-stack is too heavy for the 8 GB local kind) |

## Why our own client (unchanged from Track 1)

We run **our own Rust `ds-bench`** containerized as the client, keeping full SSE
fidelity (payload-embedded ns timestamp → `now − sent`, native HDR) and the highest
per-pod throughput ceiling — so the load generator is not the bottleneck. k6/xk6-sse
would be a fidelity regression; we only borrow k8s orchestration patterns, not the
client.

## Architecture / components

### ds-bench extensions (built in Track 2)
- **Serialized-HDR output + merge** (the core new feature): each client pod writes its
  HDR histogram in the `hdrhistogram` crate's serialized form to a shared sink; a
  coordinator merges them (associative, lossless) into authoritative cross-fleet
  percentiles + aggregate ops/s. Today `ds-bench` emits only a per-process JSON
  summary — this adds the serialized-histogram emit + a merge step.
- **`mixed` workload:** concurrent writers + catch-up readers + live SSE subscribers
  on shared streams, fixed ratio, scaled together. Most realistic. Run against
  DS-rust, DS-node, ursula (NOT S2 — it has no comparable catch-up read).
- Reuses (already built in Track 1): multi-stream, fan-out, catch-up workloads and the
  `--api-style {durable|ursula|s2}` backends. The 5 forked ursula-bench files stay
  byte-identical; new code lives in our own modules.

### Distribution layer (k8s)
- `ds-bench` containerized (image exists); fanned out as a **k8s Job (parallelism = N
  pods)** per workload/system, scaled to keep the server-under-test saturated.
- **Aggregation:** pods write serialized HDR to a shared sink — a **PVC** locally /
  **object store** on GKE; a **coordinator** (init step or a final Job) merges →
  unified percentiles. Method borrowed from OpenMessaging Benchmark's HDR-merge (the
  method, not its Java workers).
- **Images:** local kind → `kind load docker-image` (no registry, no login). GKE →
  push to Artifact Registry (or the cluster's registry).

### Server deployments (k8s)
- **durable-streams (Rust):** our Deployment + Service; runs the raw-only binary
  (no `--http-engine` flag post-refactor), `--tier s3` → in-cluster MinIO.
- **durable-streams (Node/TS):** our Deployment + Service; built from the Node server
  in `../durable-streams`; cold tier → MinIO.
- **ursula:** its **existing Helm chart** at 1/3/5 replicas, disk-WAL Raft, cold tier → MinIO.
- **S2 Lite:** Deployment from `ghcr.io/s2-streamstore/s2` (`lite … --bucket … --path …`),
  `AWS_ENDPOINT_URL_S3` → MinIO.
- **Object store:** MinIO in-cluster (same buckets as Track 1, namespaced per system).

## Phasing

- **Phase 2a — local kind (8 GB), MECHANICS validation.** Portable manifests +
  Helm + a `kind`-based run script. Stand up MinIO + **one** server + a **small**
  client fleet (2–3 pods) + the coordinator; run all four workloads at **tiny scale**;
  confirm: manifests apply, the Job fleet fans out, **serialized HDR merges** into
  unified percentiles, MinIO offload works, S2 is correctly limited to write+fan-out.
  **No kube-prometheus-stack** (8 GB can't hold it) — merged-HDR JSON is the source of
  truth. Goal: prove the harness is correct, **not** to measure scale (a laptop can't
  saturate these servers).
- **Phase 2b — GKE load-testing cluster, REAL numbers.** Same manifests, promoted:
  full client fleet to saturate each server, ursula at 1/3/5, a pinned
  c7g-equivalent node pool with explicit requests/limits, Prometheus + Grafana,
  images in Artifact Registry, a **dedicated namespace** (named by the user; I never
  touch an existing GKE context without explicit direction).
- **Phase 3 — DS-rust multi-node** (when it lands): true 3-node ↔ 3-node and
  5-node ↔ 5-node, bringing ursula's replication into the head-to-head.

## Experiment matrix (first GKE run — Phase 2b)

- **Workloads:** write-throughput, SSE fan-out, catch-up, mixed.
- **Systems × topology:** DS-rust ×{1}, DS-node ×{1}, ursula ×{1, 3, 5}, S2 Lite ×{1}
  (S2 write+fan-out only). DS-rust ×{3,5} joins in Phase 3.
- **Sweeps:**
  - writes: payload 100 B / 1 KB / 16 KB; **client-pod count scaled to saturation**.
  - fan-out: subscribers 100 → 1k → 10k across client pods.
  - catch-up: backfill size sweep, hot (tail) vs cold (object store).
  - mixed: fixed writer/reader/subscriber ratio, scaled together.
- **Headline outputs:**
  - per-system **saturation ceiling**: max throughput + p99/p999 as client pods scale
    (the new distributed capability).
  - ursula throughput + tail vs **server-node count** (scale-out efficiency curve).
  - fan-out latency vs **subscriber count**, all systems.
  - single-node head-to-head carried from Track 1.

## Fairness controls (carried from Track 1)

- Matched durable-to-disk: ursula `[raft.wal] backend = "disk"`; durable-streams fsync;
  all offload to the same MinIO. **Group-commit-symmetry** disclosed.
- **S2 durability disclosure:** S2 Lite writes through SlateDB to object storage on the
  write path (~50 ms default flush) — a different substrate, stated plainly, run at
  default flush (not tuned to fake parity); S2 limited to the 2 comparable workloads.
- Pinned, identical pod/node resources (c7g-equivalent on GKE) and explicit
  requests+limits; one server-under-test per measured run; identical `ds-bench` params
  across systems; load-generator headroom monitored so it never bottlenecks.
- **Multi-node honesty (critical):** at 3/5 nodes ursula pays cross-node replication
  that the single-node systems do not. Report two **separate** stories until Phase 3:
  (a) single-node head-to-head, (b) ursula's own scale-out curve. Never headline a
  single-node DS number against a 3-node ursula number.

## Open items (resolved in planning/implementation)

1. **Serialized-HDR merge mechanism** — emit format from `ds-bench`, shared sink (PVC
   locally / object store on GKE), and the coordinator (init container, final Job, or
   a small script) that discovers + waits for all pods and merges.
2. **`mixed` workload design** — writer/reader/subscriber ratio + how it shares streams;
   S2 exclusion.
3. **kind run harness** — cluster config, `kind load` image flow, namespacing, the
   tiny-scale fleet sizing that fits 8 GB.
4. **GKE specifics (Phase 2b)** — cluster + namespace (user-named), node pool, Artifact
   Registry push, kube-prometheus-stack install.
5. **Client-fleet sizing** — pods needed to saturate each topology without the
   generator bottlenecking (empirical, monitored).
6. **DS-node server image + manifest** — building/running the Node DS server in k8s.

## Success criteria

- **Phase 2a (local kind):** manifests apply on kind; MinIO + one server + a small
  ds-bench Job fleet run all four workloads at tiny scale; **per-pod serialized HDR
  merges into unified percentiles**; S2 correctly limited to write+fan-out; MinIO
  offload verified. (Correctness, not scale.)
- **Phase 2b (GKE):** full fleet saturates each system; ursula runs at 1/3/5;
  Prometheus/Grafana live; a rendered report shows, per workload: saturation ceiling
  (throughput + p99/p999 vs client pods), ursula scale-out vs node count, and fan-out
  latency vs subscriber count — across DS-rust, DS-node, ursula 1/3/5, and S2 Lite
  (2 workloads), with the single-node vs multi-node and S2-substrate disclosures explicit.
