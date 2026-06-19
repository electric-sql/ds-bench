# durable-streams server — benchmark findings & io_uring readiness

**Date:** 2026-06-19 · **Harness:** `ds-rust-bench` (branch `track2-phase2b`) · **Server under
test:** `vbalegas/streams-rust` @ `d39ad487` (tier-compaction + fd/create fixes).
**Hardware:** GKE `n2d-standard-8`, local NVMe SSD data dir, in-cluster MinIO cold tier.

> Server-side patches referenced below live **uncommitted** in `../durable-streams` for review —
> nothing is committed to the server repo.

---

## 1. Executive summary

- The suite runs reproducibly on **local kind** and **cloud GKE** from the same scripts
  (`DS_TARGET=local|remote`) — same commands → side-by-side comparison.
- The two limits that bounded earlier runs are **fixed and confirmed**: the ~1024-connection
  hang (now `NOFILE=1,048,576`, server handles 4096+ conns) and the ~200-concurrent-stream
  creation timeout (creation now runs off the async pool).
- **io_uring deployment is ready on both targets** — only a pod `seccompProfile: Unconfined`
  is required, and it is already in the manifest. No separate Linux VM, no special kind config.
- Three deeper investigations (fsync/group-commit, per-connection memory, disk throughput) each
  produced an actionable result and, for two of them, a candidate patch.
- **Key reframe:** at cpu=4 this server is rarely CPU-bound — its real ceilings are **fsync,
  memory, latency, and per-stream serialization**, not CPU and (for a single stream) not even
  the disk. Adding client machines beyond ~64 pods does **not** raise server CPU.

---

## 2. Server limits — confirmed fixed

| limit | symptom (before) | fix (in `d39ad487`) | confirmed |
|---|---|---|---|
| fd / 1024 conns | server stalled at exactly 1024 conns, no recovery | `raise_nofile_limit` (setrlimit → hard limit) + accept-loop EMFILE backoff | `NOFILE=1048576`; 4096 conns OK, server `1/1` |
| stream creation | concurrent `PUT /v1/stream` timed out at ~200 | `store.create` on `spawn_blocking` (off the async worker pool) | N=200 multi-stream completes (238k ops/s) |

These were harness-visible mislabels of real server limits — both lifted.

---

## 3. fsync / group-commit

**Mechanism.** `SyncCoalescer` (`store.rs:136`) is a leader/follower group commit: the first
appender to find no fsync in flight becomes the **leader** and fsyncs on behalf of all
**followers** that arrive while `in_flight=true`; one `fdatasync` makes everything ≤ `covers`
durable. Durability gate: a follower never returns until `synced ≥ target`.

**The bug.** The leader snapshotted `covers = tail` **immediately**, with zero delay
(`store.rs` leader branch), so it only folded in appends written in the microsecond before the
snapshot — anything written a moment later became the *next* leader → its own fsync. Under load
it degraded toward **~1 fsync per append** (group commit in name only; `ARCHITECTURE.md` claims
"~one fsync per batch" but the code never waited). **Patch (uncommitted):** a
`--group-commit-window-us` knob + `sleep(window)` *before* the `covers` snapshot, so concurrent
appends fold into one fsync. Durability preserved (covers read after the wait; default 0 =
identical to today). `store.rs +42, main.rs +8`, all 41 tests pass.

**BUT — measured, the window made no difference.** A sweep (window `{0,200,500}µs` × payload
`{1K,16K,256K}`, single stream, 2048 concurrent appenders, cpu=4, 4 striped SSDs) gave identical
throughput across windows. Interpretation: **at high concurrency the fsync already coalesces
naturally** (appenders pile up as followers during one fsync's duration), so an explicit window
is redundant, and the single-stream ceiling is **bound by the per-stream write serialization**
(the appender lock: write→publish→unlock is serial, ~11 µs/op → ~90k/s @ 1K), **not by the fsync
rate and not by the disk**.

→ **For max single-stream append speed the group-commit window is the wrong lever; cross-stream
parallelism is.** Where the window *should* help is **low concurrency** (few appenders, no
natural batching) — worth a targeted re-test, ideally with the server built `--features
telemetry` so `ds.append.fsync.batch_size` is observable instead of inferred. **Open for the
implementor.**

---

## 4. Per-connection memory (SSE fan-out)

~40k SSE subscribers OOM-killed the 6 GiB server → **~150 KB resident per subscriber**.
Accounted with a counting allocator:

| component | bytes | note |
|---|---|---|
| **kernel TCP recv buffer** (autotuned ~128 KiB, charged to cgroup) | ~128 KiB | **dominant** |
| read buffer `BytesMut(16K)` | 16 KB | `engine_raw.rs:153` |
| SSE frame `Vec(8K)` | 8 KB | `engine_raw.rs:286` |
| `mpsc::channel(8)` | 1.5 KB | fixed block; events are `Bytes`/Arc-shared, so the queue is cheap |
| task + head + watch | ~0.8 KB | |

Rust heap is only ~27 KB — **the cost is the kernel socket buffer**, not the app. SSE sockets are
receive-light yet pin a fully-grown rmem. **Patch (uncommitted, `engine_raw.rs +35/−2`):** cap
`SO_RCVBUF`/`SO_SNDBUF` to 64 KiB + shrink read (16K→4K) and SSE frame (8K→512B) buffers →
**~77 KB/subscriber → ~13–14k subs/GiB → the 6 GiB OOM ceiling moves ~40k → ~80k**. For more:
a custom SPSC instead of `mpsc`, and an SSE-specific socket cap (`SO_RCVBUF` is bounded by the
node `net.core.rmem_max`).

---

## 5. Disk throughput

- `/data` is genuinely on **local NVMe SSD** (`df` → `/dev/md0`, RAID0). A **single** GCP local
  SSD caps write at ~350–660 MB/s (per-device). **Stripe more:** `LOCAL_SSD_COUNT` (harness knob,
  RAID0, ≈ 0.6 GB/s × count; max 16 on n2d-standard-8 → ~9 GB/s).
- **Ground-truth disk metric added** — the sidecar samples `/proc/<pid>/io write_bytes` →
  disk MB/s in the renderer (was ops×payload estimate only).
- Single-stream append disk MB/s by payload (cpu=4, 4 SSDs): **1K → 129, 16K → 519, 256K → 759
  MB/s** — climbs with payload but **plateaus at ~759 MB/s, only ~⅓ of the ~2.4 GB/s 4-SSD
  ceiling**. One stream's serial write path cannot drive the disk.
- **To max disk throughput: multi-stream × large payloads** (parallel streams' fsyncs overlap →
  toward the device ceiling). The first multi-stream check used the 256-byte default (14 MB/s —
  invalid for a disk test). **Open: corrected experiment** (streams `{10,50,200}` × payload
  `{16K,256K,1M}`).

---

## 6. io_uring deployment readiness

The new io_uring server is a **drop-in** (same binary name, CLI flags, port 4438, `/v1/stream`
paths, `--tier s3`) — the harness is unchanged except that io_uring syscalls must be permitted.

**Cloud (GKE):** confirmed **Standard** (not Autopilot), **COS** node image, **kernel 6.12.68**
(≥ 6.0 → io_uring *and* `IORING_OP_SEND_ZC` zero-copy-send both work), **no gVisor/sandbox**. The
server pod now sets `securityContext.seccompProfile.type: Unconfined` (Docker 25 / CIS default
seccomp blocks `io_uring_setup/enter/register`, moby#46762). Unconfined is a superset → reference
/ ursula / s2 unaffected. **Do not route this pod through gVisor** (no io_uring there).

**Local (kind): works directly — verified empirically.** kind launches its node containers
`--privileged` with `seccomp=unconfined apparmor=unconfined`, so the *node* doesn't block
io_uring; the only gate is the **pod's** `seccompProfile`. Test: an `Unconfined` pod →
`io_uring_setup` returns an fd (PERMITTED); a `RuntimeDefault` pod → EPERM (BLOCKED). Docker
Desktop's VM kernel is **6.10** (≥ 6.0), so **io_uring + zero-copy-send both work inside kind** —
no separate Linux VM, no special kind config. (Outside k8s, `docker run --security-opt
seccomp=unconfined …` works too for a single-instance smoke.) The earlier "kind = splice only"
note was wrong and has been corrected in `BENCHMARKING.md`.

---

## 7. The harness (for reproducibility)

- Modularized: shared engine `scripts/lib-bench.sh` + `scripts/target-env.sh`; runners are
  matrix-only; renderers share `scripts/render_common.py`.
- `DS_TARGET=local|remote`; lifecycle helpers `cluster-up.sh` / `build-images.sh` /
  `cluster-down.sh`; `run-one.sh` (one phase per cluster, parallelizable).
- Client tuned for high fan-out: raises its own `RLIMIT_NOFILE`, unbounded idle pool, fatter
  pods (so one load-gen pod sustains thousands of connections).
- Full runbook + config reference: **`BENCHMARKING.md`**.

---

## 8. Open items / next steps

1. **Group-commit window** — implementor to confirm per-stream serialization vs fsync; low-
   concurrency re-test + `--features telemetry` (`ds.append.fsync.batch_size`).
2. **Corrected disk experiment** — multi-stream × large payloads → max append MB/s + fsync-
   coalescing-across-streams proof.
3. **Fan-out capacity** — re-run with raised server memory to chart subscribers-vs-OOM and the
   per-subscriber cost after the socket-buffer patch.
4. **Decide on the two server patches** (group-commit window; socket-buffer caps).
5. **Harness verdict fix** — add a throughput-plateau check so fsync/latency-bound cells read
   `server_bound` instead of mislabeled `client_capped`.

## Appendix — uncommitted server patches (`../durable-streams/packages/server-rust`)
- `store.rs` + `main.rs`: `--group-commit-window-us` group-commit accumulation window.
- `engine_raw.rs`: per-connection socket-buffer caps (`SO_RCVBUF/SNDBUF` 64 KiB) + smaller
  read/SSE buffers.
