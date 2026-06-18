# Ursula fan-out p99 outlier diagnostic

## The anomaly

Our GKE single-node run measured ursula **fan-out p99 = 916 ms** vs ursula's published
**3-node p99 = 8.3 ms**. That is a **110× gap** — far too large to be explained by
node count (3 → 1) or core reduction (16 → 8). We do not trust this number yet
([benchmark-findings.md §5](./benchmark-findings.md#5-️-the-ursula-fan-out-p99--916-ms-outlier-do-not-publish-yet)).

**Hypotheses:**
- **(a) Commit latency + delivery stall:** ursula's slow single-node Raft machinery
  (multi-stream write p99 = 309 ms) delays event visibility; under heavy subscriber
  load (500 subscribers in our test), SSE delivery queues back up, pushing fan-out
  p99 past 900 ms.
- **(b) Subscriber overload:** SSE delivery is genuinely hitting a backlog wall at
  high subscriber counts, not commit-bound but delivery-queue-bound.
- **(c) Harness or configuration artifact:** test setup, pod placement, network
  contention, or ursula config (Raft group count, preset) accidentally suppressed
  throughput on this single run.

---

## Procedure

### 1. Re-run ursula fan-out in isolation

**Setup:**
- Single ursula server pod (no co-located client).
- Single client pod (sole subscriber/writer).
- Fixed subscriber count: start with **100**, then sweep to 500, 1k.
- Fixed writer rate: match the original test (~1k writes/s), or let it saturate.
- Duration: ≥30 s; capture merged HDR histogram.

**Command reference:** `scripts/gke-run.sh ursula fan-out --subscribers=100` (adjust
as needed; consult `gke-run.sh` for exact flag names).

**Output:** merged histogram with p50, p99, p999 latencies; throughput (events/s).

### 2. Decompose the latency

Compare the baseline data from `bench-history/runlog.tsv`:
- **ursula multi-stream write p99:** 309 ms (row: `ursula preset-standard multi-stream`).
- **New fan-out p99:** from step 1.

**Test the hypothesis:**
- If **new fan-out p99 ≈ 309 + ~100–200 ms** (commit latency + modest delivery
  overhead), the culprit is commit-induced and the 916 ms is real but explained.
- If **new fan-out p99 ≪ 916 ms** (e.g., <100 ms at 100 subscribers), the original
  916 ms is load-dependent or an artifact.
- If **new fan-out p99 stays ≥900 ms**, we have a deeper bug.

### 3. Subscriber sweep

Run fan-out at **100, 500, 1k subscribers** with the same writer rate and duration.

**Decision rule:**
- **Flat tail across subscriber counts** (all p99 ≈ 100 ms, say): artifact, not a
  load-induced backlog. Investigate harness/config.
- **Linear or accelerating p99 with subscriber count** (100 → 200 ms, 500 → 600 ms,
  1k → 900 ms): load-induced, **keep the number with disclosure** in the findings
  doc.
- **Sudden cliff** (100 → 200 ms, 500 → 900 ms): admission control or queuing
  threshold; note it as a real constraint on ursula's scalability under single-node
  deployment.

### 4. Cross-check against DS-rust and S2 Lite

Run the same 100 / 500 / 1k subscriber sweep against DS-rust and S2 Lite with
identical params (same writer rate, duration, subscriber-count steps).

**Validation:**
- If DS-rust and S2 stay flat and fast (p99 ≤ 100 ms) across the sweep, ursula's
  cliff is ursula-specific (commit latency + delivery), not a harness issue.
- If **all three systems degrade together**, the harness itself is the bottleneck
  (e.g., pod placement, network overload, client-side serialization).

---

## Decision rule and outcome

**If reproducible and explained (commit + backlog):**
- Keep the 916 ms number in `docs/benchmark-findings.md` §5 **with explicit
  disclosure:** "ursula single-node fan-out p99 = 916 ms under 500 subscribers;
  latency degrades with subscriber count due to Raft commit delays (309 ms p99)
  compounding SSE delivery overhead. This is single-node behavior; ursula's 3-node
  p99 = 8.3 ms is not directly comparable."

**If it vanishes or is load-independent:**
- Drop the 916 ms from any blog post or public claim.
- Re-run a clean ursula fan-out measurement at a representative (e.g., 10–50
  subscribers) single-node level.
- Update `docs/benchmark-findings.md` §5 with the new, trustworthy number.

**In either case:** record the outcome (decision, new p99 if measured, reasoning) as a
new row in `bench-history/runlog.tsv` and update §5 with a note: "Diagnostic
re-run [date]: [outcome]."

---

## Cluster and access

This is a **cluster-gated run**: requires the GKE cluster `ds-bench` to be up.
- Cluster provisioning: `scripts/gke-up.sh` (currently down; will be re-provisioned
  for Phase 2b).
- Run entry point: `scripts/gke-run.sh`.
- Teardown: `scripts/gke-down.sh`.

All runs record results to MinIO; a local coordinator merges histograms and emits to
`bench-history/runlog.tsv` and result files to `results-gke/`.
