# Benchmark findings — durable-streams vs ursula vs S2 Lite (blog prep)

**Date:** 2026-06-18 · **Status:** working notes for a blog post · single-node, GKE
`n2d-standard-8`, object tier = in-cluster MinIO on local NVMe.

> These are honest working notes, not marketing. Every number here has a caveat;
> the caveats are the point. Two items are explicitly **not yet trustworthy** and
> flagged inline: the ursula fan-out p99 outlier, and the (discarded) preset sweep.

---

## 1. The headline, and why it must be read carefully

Single-node, same 8-core node, same NVMe, same client (ursula's own `ds-bench`
workloads), matched durability (both fsync to disk), one server at a time:

| workload | DS-rust | ursula (preset standard) | S2 Lite |
|---|---|---|---|
| **multi-stream write** — writes/s · p99 | **78,490** · 24 ms | 7,611 · 309 ms | 15,323 · 72 ms |
| **fan-out** — events/s · p99 | **119,984** · 47 ms | 44,791 · **916 ms ⚠️** | 84,920 · 63 ms |
| **catch-up** — MB/s · p99 | 786 · **7.5 ms** | **988** · 59 ms | — (excluded) |
| **saturation** (DS-rust write, pods 2→4→8) | 84k → 181k → **200k** | — | — |

DS-rust leads writes (~10× ursula, ~5× S2) and fan-out throughput; its catch-up
**latency** is ~8× lower. But this is a single-node, NVMe, 8-core snapshot, and
two of these numbers are not yet trustworthy (§5, §6). Read on before quoting any
of it.

---

## 2. Reconciling with ursula's published benchmark (the important part)

ursula publishes (https://ursula.tonbo.io/benchmark/) a benchmark where **ursula
wins ~12×**: ursula 41.6k ops/s vs "Durable Streams" 3.4k vs S2 6.0k. Our result
is the *opposite*. That inversion is almost entirely explained by **what was
measured**, not by either side cheating:

**Their setup (favours ursula, defensibly):**
- **"Durable Streams" = the Node/TypeScript reference server**, not a Rust server.
  The Rust durable-streams server is **not released yet**, so the only public DS
  implementation to benchmark was the Node reference — which is the single-process
  "easy to run on a laptop" reference impl. So their "12× faster than Durable
  Streams" is largely **Rust-beats-TypeScript** (we measured ~20–250× Node↔Rust
  gaps elsewhere), not architecture-beats-architecture.
- **ursula 3 nodes (3× c7g.4xlarge = 48 cores), competitors 1 node.** They disclose
  this ("Ursula gets 3× the hardware").
- **ursula's hot write path does no disk fsync** — in-memory Raft ring, durability
  via quorum, S3 flush in the background. The Node DS server fsyncs **to an EBS
  volume** (network block storage, slow fsync). On EBS, the fsync-bound system loses
  badly.
- **Replay isn't apples-to-apples:** ursula uses `/bootstrap` (snapshot + tail);
  DS/S2 replay the full log (they disclose this too).

**Our setup (favours DS, more controlled):**
- We benchmark the **unreleased Rust** durable-streams server. Different system from
  their Node number — **our numbers and theirs are not comparable**; ours is the
  first Rust-vs-ursula data point.
- **Both single-node, same 8-core node, same NVMe, same client.**
- **Matched durability:** both fsync to disk. This forces single-node ursula into
  its **disk-WAL mode** (`[raft.wal] backend=disk`) — because with no peers, the
  only durability is local fsync. That is **not ursula's intended mode** (it's built
  for quorum, where the hot path doesn't fsync).

**Net:** the disk alone flips the story. The *same Rust DS server* would do ~3.4k on
EBS and ~78k on NVMe — a **~23× swing from disk choice**. Neither "DS wins 10×" nor
"ursula wins 12×" is *the* truth; each holds only under its stated framing.

---

## 3. Why the write p99 differs (24 / 72 / 309 ms)

The three systems have structurally different write paths:

- **DS-rust — 24 ms p99 (p50 9.6).** Append → in-memory buffer → **group-commit
  fsync to NVMe** → ack. Group commit coalesces concurrent appends into one fsync;
  NVMe fsync is sub-ms. Tail spread p50→p99 is only ~2.5× → no pathological stalls.
- **S2 Lite — 72 ms p99 (p50 51).** Append → SlateDB memtable → periodic flush to
  the object store (~50 ms default cadence). The ~51 ms p50 *is* that flush window;
  tight tail (51→72).
- **ursula — 309 ms p99 (p50 92).** Append → openraft propose → append+fsync Raft log
  → commit → **state-machine apply** → ack — *every* write, even single-voter. The
  92 ms p50 is the floor of that consensus+apply pipeline; with 256 Raft groups on 8
  cores (32 groups/core), scheduling and lock contention fatten it to 309 ms p99.
  This is ursula's machinery doing on one node the work it's designed to do across
  three — it pays for replication it isn't getting any benefit from here.

**Takeaway for the post:** on a single node with fast local disk, a thin
append+group-fsync path (DS) beats a full consensus log (ursula) and an
LSM-to-object path (S2) on write latency. That's expected, and it's the honest
single-node story — *not* a claim about ursula's 3-node deployment.

---

## 4. Why the catch-up latency differs (7.5 ms vs 59 ms p99)

Catch-up = N clients each replay a pre-loaded stream (~200 events × 1 KiB).

- **DS-rust — 786 MB/s, 7.5 ms p99.** `GET ?offset` → the server does a
  **zero-copy / sendfile range read** from the contiguous segment file. No
  per-record serialization → very low per-read latency.
- **ursula — 988 MB/s, 59 ms p99.** Higher aggregate MB/s but **8× the latency**.
  ursula returns larger, framed responses per round-trip (more bytes per response →
  higher MB/s) but each response costs more to assemble/serialize/transfer.

**Comparability caveat (must state in the post):** the MB/s figures are
**confounded** — ursula's responses carry more bytes per logical record (framing /
enveloping), so "MB/s" is not a like-for-like unit here. Lead with **latency**,
where DS-rust's zero-copy read path is decisively faster (7.5 vs 59 ms p99). One
thing *more* honest in our harness than theirs: we force **full-log replay on both**
(our offset-loop catch-up), whereas their benchmark let ursula use `/bootstrap`
(snapshot, less data) against DS/S2's full replay.

---

## 5. ⚠️ The ursula fan-out p99 = 916 ms outlier (do NOT publish yet)

Our single-node ursula fan-out p99 is **916 ms**; ursula's *published* 3-node
fan-out p99 is **8.3 ms**. That's a **110× gap** — far more than node count (3→1) or
cores (16→8) can explain. Fan-out latency = commit latency + SSE delivery; ursula's
slow single-node commit (§3) delays event visibility, and under 500 subscribers the
tail may be a backlog blow-up — **or** a harness/config artifact. Until a clean
re-run confirms it, treat 916 ms as **not trustworthy** and do not use it to claim a
fan-out win over ursula. (DS-rust 47 ms and S2 63 ms look internally consistent.)

---

## 6. ⚠️ The preset sweep was invalidated (must re-run cleanly)

We tried to find ursula's best `--preset` (Raft group count) on this machine. A
**concurrency bug in our own harness** — two background runners mutating the same
ursula deployment's `--preset` at the same time — corrupted the probe numbers
(`standard` came back 2,684 vs `tiny`/`small` ~7,000, an impossible inversion). Those
probes are **discarded**. What we *do* trust: ursula no-preset = 6,190 → preset
`standard` = **7,611** writes/s (a clean ~+23% from giving it its intended group
parallelism). A clean preset sweep is **pending**; the architectural ~10× gap to
DS-rust stands regardless of preset (7.6k is the same order as the 6–9k ursula
single-node has shown everywhere).

---

## 7. Scalability question — can ursula's in-memory hot-ring design hold millions of streams?

ursula's pitch is "millions of streams" on an **in-memory hot Raft ring** + offload
to S3. The obvious question: **what happens when the streams don't fit in memory?**
Verified against ursula's source (commit pinned in `vendor/ursula`):

**Hot DATA tiering is real and ursula-owned (not delegated).** Each Raft group caps
hot payload at `max_hot_size_per_group`, default **64 MiB, enabled**
(`ursula-config/src/config.rs:279,316`). ursula's *own* planner picks what to flush
(`StreamStateMachine::plan_next_cold_flush_batch`, `state_machine.rs:709-792`); a
background timer (default **1 s**, `config.rs:311`) flushes ≥8 MiB chunks to S3 and a
flushed chunk's bytes are **evicted** from the per-stream `HotBuffer`
(`HotBuffer::flush_prefix`, `state_machine.rs:385-401`; write `cold_store.rs:420`).
`opendal` is just the S3 byte-transport — the when/what is ursula's, **unlike** S2
Lite which leans on SlateDB's LSM to self-tier.

**BUT three things break the "millions of streams" claim:**

1. **Cold storage is OFF by default.** `ColdBackend` defaults to `None`
   (`config.rs:307`) and **no preset (tiny/small/standard/large) enables it** — you
   must hand-configure `[storage.cold]`. Out of the box there is *no* offload: the
   64 MiB cap is a **write-rejecting admission gate** (503 `ColdBackpressure`,
   `engine/in_memory.rs:790-813`), not elastic eviction. Crossing the limit
   **rejects the write**; it does not trigger a flush.

2. **⭐ Per-stream STATE is unbounded in RAM and grows with stream COUNT — the
   load-bearing risk.** The state machine holds **eight per-stream maps** (metadata,
   attrs, hot_buffers, message_records, integrities, visible_snapshots, producers,
   cold-index frontier; `state_machine.rs:46-59`), evicted **only on stream delete**
   (`remove_stream_state`, `state_machine.rs:2432`) — **never on flush**. A
   fully-flushed idle stream still costs metadata + an empty HotBuffer + integrity +
   a producers sub-map. **Producer dedup state has no cap/TTL** — every producer-id
   that ever wrote keeps a `ProducerState` (with `last_items: Vec<…>`) forever. There
   is **no `max_streams_per_group`, no producer cap, no retention** anywhere in
   config. The 64 MiB cap counts only hot *payload* bytes — **not** this map
   overhead. So flushing hot DATA frees payload bytes but the per-stream STATE stays
   resident. (It also makes flush O(n log n) in stream count *per group per second* —
   `state_machine.rs:719`.)

3. **Raft log + snapshots scale with stream count too.** `SnapshotPolicy::Never`
   (`engine/factory.rs:632`), **no automatic log purge** (manual admin endpoint only,
   `lib.rs:1209`), and snapshots are **full, non-incremental JSON of the entire
   group** — all streams + their hot payloads — on a 60 s timer
   (`ursula-raft/src/state_machine.rs:564`; `bootstrap/snapshot.rs`). Both log size
   and per-snapshot cost grow O(streams-per-group).

**Cold-read latency** (when enabled): a read of evicted data can take **two
sequential S3 GETs** (cold index page miss → data block miss), each with timeout +
retries; the read cache (256 MiB LRU) and index-page cache (1024 pages) are bounded —
but the read cache also **defaults to `None`** (`config.rs:309`).

**And their published benchmark never exercises any of this** — 500–2k streams,
~675 MiB, all hot-path, almost certainly cold-disabled. The millions-of-streams +
eviction + cold-read story is an **architectural claim, not a benchmarked result**.

**Bottom line:** "millions of streams that exceed memory" holds **only for stream
payload DATA** (and only when cold storage is explicitly enabled, which no preset
does). For stream **count**, ursula keeps unbounded per-stream state + producer state
in RAM per group with no eviction or count caps, and an unpurged Raft log — so stream
*cardinality*, not data volume, is the real memory ceiling. Sharding across more
groups spreads it but doesn't change the per-stream-state-in-memory fundamental.

---

## 7a. The architectural takeaway (positioning thesis)

The scalability finding generalizes into the core positioning point:

> **To serve datasets beyond memory, disk must be the system of record and memory
> must stay bounded — not grow with stream count.** A design that holds per-stream
> *state* in RAM is bounded by stream *cardinality*, no matter how well it offloads
> stream *data*.

- **ursula** keeps the hot ring + **per-stream state + producer dedup state in
  memory per Raft group**, evicted only on delete (§7). Offloading hot *data* to S3
  doesn't lower that floor. So its memory ceiling is the number of streams, and the
  "millions of streams" claim is unproven against that ceiling.
- **durable-streams is disk-first by construction**: each stream is an append-only
  segment log on disk (the read path is zero-copy `sendfile` range reads straight
  from those files — which is exactly why its catch-up p99 is 7.5 ms, §4), sealed
  segments tier to object storage, and the working set in memory is bounded rather
  than scaling with the number of streams. That's what lets it carry **millions of
  streams**: the disk (and cold tier) is the dataset; memory is a bounded cache.

⚠️ **Honesty guard (to keep this defensible):** the durable-streams half of this
claim is being **verified in source the same way we audited ursula** — confirming
that per-stream state is disk-backed/bounded (not an in-memory map that grows with
stream count), the segment-per-stream on-disk layout, and the memory behaviour at
high cardinality. We will not publish "built for millions of streams" as a bare
assertion; it gets the same file:line scrutiny ursula got, and a cardinality
benchmark (many-streams, exceeding RAM) is the experiment that would actually prove
it — neither benchmark here has run that yet.

---

## 8. Disclosures we MUST carry in any public writeup

1. **Single-node only.** ursula is built for 3-node quorum (no hot-path fsync);
   single-node forces it into disk-WAL mode — *not* its intended deployment. 3v3
   waits for durable-streams multi-node (Phase 3). Cite ursula's own 41.6k 3-node
   number for context.
2. **Different DS implementation than their benchmark.** We test the (unreleased)
   **Rust** server; their "Durable Streams 3.4k" is the **Node reference**. Numbers
   are not cross-comparable.
3. **Disk dominates absolutes.** MinIO-on-NVMe object tier; same NVMe for all. The
   single biggest reason our DS number is 23× theirs is NVMe vs their EBS.
4. **8-core node**, not ursula's published 16-core class; ursula is thread-per-core
   and likely scales with more cores.
5. **S2 substrate:** SlateDB write-through to object store at default flush; excluded
   from catch-up + mixed (incomparable read path).
6. The **fan-out 916 ms** and the **preset sweep** are unverified (§5, §6).

---

## 9. Method (for reproducibility)
- Cluster: GKE `ds-bench`, 1× `n2d-standard-8` (`role=server`, local NVMe) + 2×
  `n2d-standard-16` (`role=client`), in the `benchmarking` VPC. Object tier:
  in-cluster MinIO on the NVMe node.
- Client: `ds-bench` fleet (Indexed k8s Job) across both client nodes; each pod
  emits an HDR histogram, uploads to MinIO; a coordinator merges them **exactly**
  (lossless `Histogram::add`) — verified cross-node merge (`merged_count` = Σ pods).
- Durability: DS-rust group-commit fsync; ursula `[raft.wal] backend=disk`; both →
  same MinIO. One server-under-test per run.
- Run history: `bench-history/runlog.tsv`.
