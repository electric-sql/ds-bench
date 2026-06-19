# Phase 1 — DS-rust raw power: results

**Date:** 2026-06-19 · **Server:** durable-streams `1e9423dc` · **Hardware:** GKE
`n2d-standard-8` (NVMe local SSD), server CPU budget swept {2, 4, 8}; object tier =
in-cluster MinIO on NVMe. Load from the decoupled `ds-bench` fleet (`role=client` pool).
Run: `results/rawpower/rawpower-slow-1781826751-39316/` (23 cells with data).

> **All numbers below are `client_capped` LOWER BOUNDS** — see the server-hang finding.
> 1 repeat (not the planned 3) to fit the time budget; no median/cv.

## ⭐ Headline — read throughput scales ~linearly with server cores

| reads/s (1 KB) | 2 cores | 4 cores | 8 cores |
|---|---|---|---|
| conn 64 | 27,979 | 49,193 | **82,516** |
| conn 256 | 27,250 | 47,124 | **81,219** |
| conn 16 | 27,358 | — | 62,372 |

| reads/s (16 KB) | 2 cores | 4 cores | 8 cores |
|---|---|---|---|
| conn 64 | 23,251 | 39,791 | 56,834 |
| conn 256 | 22,168 | 36,932 | 55,648 |

- **~3× from 2→8 cores** (1 KB: 28k → 82k reads/s). Efficiency ~14k → 10k reads/s/core
  (mild drop at 8c — partly the client becoming the limit).
- **p99 is low and improves with cores** — 8c/1KB: 0.96–15 ms; 8c/16KB: 1.1–29 ms.
- Server CPU scales with cores (2c ~145% → 4c ~295% → 8c ~420–530%), confirming the read
  path is CPU-bound and parallelizes — but never reached ≥90% of its allocation, so these
  are lower bounds (the client/`reads.rs` couldn't push harder without hanging the server).

## Fan-out — low delivery latency, scales to 100 subscribers

| subscribers | events/s | p99 ms (8c) |
|---|---|---|
| 1 | 200 | — |
| 10 | ~2,000 | 0.99 |
| 100 | ~20,000 | **1.76** |

Single-stream fan-out delivers to 100 subscribers at ~20k events/s with **p99 ≈ 1.8 ms**
(8 cores). Clean, low-latency SSE delivery.

## Splice (1 MB binary appends)
377 / 375 / 375 appends/s at cpu 2/4/8, CPU 50–57% — got data; throughput is fsync-bound
at this payload (the splice CPU-lever comparison vs no-splice was not isolated this run).

## Partial / deferred / FAILED (need follow-up)
- **Appends (binary): unreliable.** Many cells empty; the ones with data are inconsistent
  (149 → 3,318 → 1,824 appends/s at conn 64, cpu 2/4/8) — appends are fsync/group-commit-bound
  (server CPU 0.5–12%) and several cells hit the server-hang/error path. **Not a trustworthy
  append result.**
- **Cold-tier reads: ALL FAILED** (empty) — `--tier local` cold reads errored. Investigate.
- **JSON appends: DROPPED from all phases** (not just deferred) — bytes is the realistic best
  case and is splice-eligible (zero-copy); JSON only adds client-side encoding the server
  benchmark doesn't need to chase. (The `--body-mode` capability remains in `ds-bench`, unused.)

## ⚠️ KEY FINDING — server stalls at ~1024 connections (almost certainly the fd ulimit)
The durable-streams server (`1e9423dc`) **hangs under high concurrency** (≳1024 concurrent
connections on a 2-CPU node) and **does not recover**: `curl localhost:4438` from inside the
pod times out, the deployment goes `0/1 available`, the readiness probe fails indefinitely.
Reproduced twice — once under over-seeded reads (a harness bug, fixed), once under a 4-pod
(1024-conn) append fleet. Consequences:
- I capped the matrix at **≤512 total connections** (PARALLELISM=2, conns ≤256, subs ≤100)
  to keep the server alive — which is **why every number is a `client_capped` lower bound**
  (the headroom guard can't saturate the server without hanging it).
- The append-heavy and cold-tier cells (heavier load) failed.

**UPDATE (2026-06-19) — this is almost certainly the file-descriptor ulimit, NOT a deadlock.**
The wall sits at *exactly* 1024 connections (the append hang was 4 pods × 256 conns = 1024),
which is the classic default soft `RLIMIT_NOFILE`. The server (`server-rust`) never raises its
own fd limit (no `setrlimit`/`RLIMIT_NOFILE` in its source), and the pod sets no ulimit
(`gke/durable-streams.yaml` runs the server via `args` with no `command` wrapper or
`securityContext`), so it inherits the container's default soft nofile (~1024). At ~1024 open
fds, `accept()` returns `EMFILE` → no new connections accepted (incl. the readiness probe) →
*appears* hung; abruptly-killed clients leave half-open connections holding fds → no recovery.
**Fix:** raise the soft nofile — either the server `setrlimit(RLIMIT_NOFILE)` to its hard limit
at startup (proper, ~3 lines via the existing `libc` dep), or wrap the pod command with
`ulimit -n`. Then re-run to confirm the wall moves and to get true (non-fd-bound) ceilings.
The Phase-2 ~200-concurrent-*stream-creation* timeout is a separate, lower limit (200 ≪ 1024),
not fd exhaustion.

## Harness fixes made this session (committed on `track2-phase2b`)
- `reads` seed = `read_size` (the 256 MiB seed caused a cross-pod over-seed race → server OOM/hang).
- `render-rawpower.py` extracts the JSON from the coordinator's `mc cp` + JSON stdout (`merged.json` isn't pure JSON).
- **Stable per-cell stream names** — `RUN_ID` was accumulating across cells → malformed concatenated stream names → connection errors.
- **Tolerant fleet + coordinator waits** — a hung/errored cell no longer aborts the whole matrix (`set -e`); the run continues and the per-cpu fresh-server redeploy gives clean servers for the next core budget.
- Capped conns ≤256 / subs ≤100 below the hang threshold; params per your guidance: 1 K/16 K reads, 1 K/16 K append payloads, 1 K fan-out.

## Caveats
- Every cell is `client_capped` (lower bound) — not DS's true ceiling.
- Object tier = in-cluster MinIO on NVMe (near-best-case, not cloud S3).
- Server CPU% from the metrics sidecar (`/proc/<pid>/stat`), not cgroup accounting.
- 1 repeat; no median/cv.

## Cluster
**Torn down** after the run (no nodes, no billing).
