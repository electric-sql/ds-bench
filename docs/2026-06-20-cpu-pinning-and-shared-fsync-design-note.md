# Can you go faster by pinning streams to CPUs and sharing fsync?

*A design note on durable-streams (Rust server). Two tempting ideas — pin each
stream to a CPU to avoid locking, and share one fsync across the streams on that
CPU — and why, for this server's workload, they don't pay off (and the one design
where they would).*

## Setup: where the time actually goes

The server stores each stream as the **exact bytes it puts on the wire** in a
single contiguous file. A read is therefore a byte-range (`sendfile`, zero-copy);
an append is a `write` + an fsync. Two serialization facts shape everything:

- **Reads are lock-free** and syscall-bound (served zero-copy from the page cache
  or from a small resident tail cache); they scale ~linearly with cores.
- **Appends are serialized per stream** by one async mutex, and made durable by a
  **group-commit fsync** — concurrent appenders to a stream share one in-flight
  barrier-fsync.

Profiling a single hot stream under load, ~**97% of the time the append lock is
held is spent in the `write()` syscall itself** — not in lock contention, not in
the surrounding bookkeeping. Keep that number in mind; it decides everything
below.

## 1. Could we avoid the lock by allocating streams to particular CPUs?

Mechanically, yes — this is the shared-nothing / thread-per-core model. If stream
S is owned by exactly one core, that core is the sole accessor, so **ownership
replaces the mutex**. But it won't make appends faster here, for three concrete
reasons:

1. **The lock isn't the cost.** ~97% of the held time is the `write()` syscall.
   Removing a lock that isn't the bottleneck buys nothing.
2. **Connections don't map to streams.** A keep-alive connection carries requests
   for many streams, and you don't know which stream until you parse the request —
   on whatever core happened to accept the connection. A request for a stream
   owned by *another* core needs a **cross-core hand-off** (a message queue). You
   replace an uncontended mutex (~tens of ns) with a cross-core enqueue + wakeup +
   cache-line bounce — comparable or worse. The coordination moved; it didn't
   disappear.
3. **It hurts reads.** Reads are already lock-free and load-balance across a
   work-stealing pool. Pinning a stream's reads to its owner core sacrifices that
   for no gain — there's no read lock to remove.

The genuinely useful thing that single-ownership unlocks is **batching the write
syscall** (coalescing several appends into one `writev`). But you get that from a
dynamic single-writer-per-stream actor — one task that owns a stream's writes,
scheduled on any free core — *without* rigid pinning and without breaking the read
path.

## 2. Could we share one fsync across the streams pinned to a CPU?

Here is the load-bearing kernel fact: **`fsync` / `fdatasync` / `F_BARRIERFSYNC`
operate on a single file descriptor.** Each stream is its own file, hence its own
fd. **There is no syscall to fsync N files at once.** So you can only "share"
fsync in one of two ways:

**(a) Put those streams in *one* file — a shared write-ahead log.** Then a single
`fdatasync` makes all their recent appends durable: fsync amortized *across*
streams, not just within one. This is a **real** write win, and it's exactly the
intuition. The catch is that it dismantles the model — "each stream is a
contiguous file" is what makes a read a `sendfile` of a byte range. Interleave
many streams in one file and a read becomes an **indexed scatter-read**; you lose
whole-stream zero-copy. That's an architecture pivot, not a tweak.

**(b) Keep per-file, but batch the N fsync *syscalls* together** on a per-core
writer (ideally with io_uring: submit write + fdatasync for K streams in one
`io_uring_enter`). This saves *syscall* overhead — but the real cost of an fsync
is the **device cache flush**, and:

- the current design *already* gets cross-stream flush coalescing, because
  different streams' fsyncs run concurrently across the thread pool, so the device
  sees concurrent flushes and the controller coalesces them — **no pinning
  required**;
- appends here are **fsync/disk-bound, not CPU-bound**, so shaving syscall
  overhead is in the noise relative to the bottleneck.

So (b) doesn't unlock flush savings the device isn't already getting from
ordinary concurrency.

## 3. Would it make things go faster?

For this workload — no, and there's direct evidence. The concrete instantiation
of "pin streams to cores + batch submission" is the **io_uring thread-per-core
engine that was built and then dropped**: it was the *weakest appender* (≈91k
appends/s vs the raw engine's ≈208k at conn 256) and it regressed past 4 cores.
The bottlenecks are the **device fsync** and the **per-stream serial `write()`** —
neither is fixed by pinning, and cross-stream fsync concurrency is already present
without it.

## The synthesis: a write-throughput vs. read-path tradeoff

The instinct is right about *where* the win lives — **fewer fsyncs per durable
byte** is the lever. But per-file fsync makes "one fsync, many streams" impossible
unless you adopt a **shared WAL**. That design — all of a core's streams appending
into one log, one `fdatasync` per batch — is precisely how write-optimized systems
reach very high write rates (Kafka, LSM commit logs, a database's single WAL).

So the choice is fundamental:

- **This server optimizes the read / fan-out side** — contiguous file → `sendfile`,
  a resident tail cache, lock-free reads — and accepts one fsync per stream. That's
  the right call for a read-heavy, SSE-fan-out, catch-up-read workload.
- **A write-saturated, many-tiny-streams workload** would favor the shared-WAL
  pivot: it wins on writes, at the cost of an index and scatter-reads that give up
  the zero-copy read profile.

You can't maximize both. The contiguous-file decision that makes a read a
zero-copy byte-range is the *same* decision that forces one fsync per stream.
Pinning streams to CPUs doesn't escape that — only changing the on-disk layout
does.
