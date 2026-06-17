# Track 1 Addendum: protocol-faithful catch-up stampede workload

> Subagent-driven; checkbox steps. Branch `track1-catchup` from `main` @ d62b31f.

**Goal:** Add a third ds-bench workload — `catch-up` — measuring catch-up/replay read throughput, protocol-faithful (no `/bootstrap`, no `/snapshot`) and symmetric across durable-streams and ursula. Re-run and refresh the comparison.

**Architecture:** New `ds-bench/src/catch_up.rs` (OUR code) holds the stampede workload AND the catch-up read loop (as free functions using `Backend`'s public fields/methods). The forked files `backend.rs`, `common.rs`, `multi_stream.rs`, `fanout.rs`, `bootstrap.rs` stay BYTE-IDENTICAL to upstream. Only `main.rs` changes (add `mod catch_up;` + the `catch-up` subcommand) — it's already our entry point.

## Global Constraints
- ds-bench stays a verbatim fork for the SHARED workloads: do NOT modify backend.rs/common.rs/multi_stream.rs/fanout.rs/bootstrap.rs. `diff -rq` of those against `vendor/ursula/crates/ursula-bench/src/` must still show them identical (only main.rs differs, now also with the new subcommand wiring + the prior stderr line).
- Catch-up is PROTOCOL-FAITHFUL: each server is read via ITS OWN native catch-up read path; the loop treats the offset as an OPAQUE token fed back from the `stream-next-offset` response header, looping until `stream-up-to-date: true`. No snapshot, no /bootstrap.
- SYMMETRIC: identical workload params for both systems; the only per-system differences are URL shape + the "start" offset value, both VERIFIED against running servers, not assumed.
- Content-type for the pre-loaded stream: `application/octet-stream` (raw bytes; no JSON array reframing).
- edition 2024 / rust ≥1.85; the Docker bench image is rust:1.86.

---

### Task 1: catch_up.rs workload + read loop + CLI wiring + local smoke (durable)

**Files:** Create `ds-bench/src/catch_up.rs`; Modify `ds-bench/src/main.rs`.

The read loop (put in catch_up.rs; `Backend` exposes pub fields `kind`, `bucket`, `client` and pub methods `base_for(idx)`):

```rust
fn catch_up_url(b: &Backend, base_idx: usize, stream: &str, offset: &str) -> String {
    let base = b.base_for(base_idx);
    match b.kind {
        ApiStyle::Durable => format!("{base}/v1/stream/{stream}?offset={offset}"),
        ApiStyle::Ursula  => format!("{base}/{}/{stream}?offset={offset}", b.bucket),
        ApiStyle::S2      => format!("{base}/v1/streams/{stream}/records?seq_num={offset}"),
    }
}
fn catch_up_start(b: &Backend) -> &'static str {
    // durable & ursula (DS-protocol) accept -1 = start; VERIFY ursula in Task 2.
    match b.kind { ApiStyle::S2 => "0", _ => "-1" }
}
/// Loop catch-up GETs, feeding back stream-next-offset, until stream-up-to-date.
/// Returns total bytes read. Offset is opaque (format-agnostic across servers).
async fn catch_up_read_all(b: &Backend, base_idx: usize, stream: &str) -> anyhow::Result<u64> {
    use anyhow::Context;
    let mut offset = catch_up_start(b).to_string();
    let mut total: u64 = 0;
    let mut guard: u32 = 0;
    loop {
        let url = catch_up_url(b, base_idx, stream, &offset);
        let resp = b.client.get(&url).send().await.context("catch-up GET")?;
        let status = resp.status();
        if !status.is_success() { anyhow::bail!("catch-up status {status}"); }
        let up = resp.headers().get("stream-up-to-date").and_then(|v| v.to_str().ok())
            .map(|v| v.eq_ignore_ascii_case("true")).unwrap_or(false);
        let next = resp.headers().get("stream-next-offset").and_then(|v| v.to_str().ok())
            .map(|s| s.to_string());
        let body = resp.bytes().await.context("catch-up body")?;
        total += body.len() as u64;
        guard += 1;
        match next {
            Some(n) if !up && n != offset && guard < 100_000 => offset = n,
            _ => break, // up-to-date, no next, offset stalled, or guard hit
        }
    }
    Ok(total)
}
```

The workload — model the STRUCTURE on the existing `bootstrap.rs` (read it for the exact `Backend` method signatures: `ensure_namespace`, `create_stream(stream, content_type)`, `delete_stream`, `append_request(base_idx, stream, payload, producer, content_type)`, the `Producer{id,epoch,seq}` usage, `Counts`, error tallying, the `Semaphore` setup pattern, the `Barrier` stampede pattern) but make it protocol-faithful (NO snapshot publish, use `catch_up_read_all` instead of `replay_request_for`):

- `CatchUpArgs` (clap `Args`): `--target`, `--api-style` (default Ursula), `--bucket` (default `bench-catchup`), `--basin`, `--stream` (default `doc`), `--clients` (default 200), `--pre-events` (default 2000), `--event-bytes` (default 1024), `--setup-concurrency` (default 32), `--request-timeout-secs` (default 120).
- `pub async fn run(args: CatchUpArgs) -> anyhow::Result<CatchUpResult>`:
  1. build client via `common::build_client(request_timeout_secs)`; `Backend::new(api_style, &target, &bucket, &basin, client)`.
  2. `ensure_namespace()`; `delete_stream(stream)` (ignore error); `create_stream(stream, "application/octet-stream")`.
  3. SETUP (timed → `setup_elapsed_secs`): append `pre_events` payloads of `common::fill_payload(event_bytes, seed)` to `stream`, bounded by `Semaphore(setup_concurrency)`, using `append_request(0, stream, &payload, Some(Producer{id:"catchup", epoch:0, seq}), "application/octet-stream")` for Ursula/Durable (None producer for S2). Increment seq per append. Track `pre_bytes_total = pre_events * event_bytes`.
  4. STAMPEDE (timed → `stampede_elapsed_secs`): `Barrier::new(clients)`; spawn `clients` tasks. Each: wait barrier, `let t = Instant::now()`, `catch_up_read_all(&backend, idx, &stream)`:
     - Ok(bytes) → atomically add to `ok` + `bytes_received_total`; `record(&mut hist, t)` into a shared `Mutex<Histogram>` (or per-task hist merged after — mirror bootstrap.rs's approach).
     - Err whose string/status is 503/429 → `backpressure`; else → `other_err`.
  5. `aggregate_mb_per_sec = bytes_received_total as f64 / stampede_elapsed_secs / 1_048_576.0`.
- `CatchUpResult` (serde Serialize): `scenario: "catch-up-stampede"`, `api_style`, `target`, `bucket`, `stream`, `clients`, `pre_events`, `event_bytes`, `pre_bytes_total`, `setup_elapsed_secs`, `stampede_elapsed_secs`, `counts: Counts`, `bytes_received_total`, `aggregate_mb_per_sec`, `latency_ms: LatencySummary` (via `common::summarize`).

main.rs wiring: add `mod catch_up;`, add `CatchUp(catch_up::CatchUPargs)` — i.e. `CatchUp(catch_up::CatchUpArgs)` — variant to the `Cmd` enum with doc comment `/// Catch-up stampede ...`, and a dispatch arm `Cmd::CatchUp(a) => serde_json::to_string_pretty(&catch_up::run(a).await?)?`.

- [ ] Step 1: Write catch_up.rs and wire main.rs.
- [ ] Step 2: `cd ds-bench && cargo build --release` — compiles clean.
- [ ] Step 3: Verify the 5 forked files are still verbatim: `diff -rq <(git show vendor/ursula:... )` is awkward; instead `diff -q ds-bench/src/backend.rs vendor/ursula/crates/ursula-bench/src/backend.rs` (and common/multi_stream/fanout/bootstrap) → all identical. Confirm `ds-bench --help` now lists `catch-up`.
- [ ] Step 4: Local smoke vs durable-streams: build/run `durable-streams-server` (hyper, tier off) like scripts/smoke-durable.sh; run `ds-bench catch-up --target http://127.0.0.1:PORT --api-style durable --clients 16 --pre-events 500 --event-bytes 512`; assert `counts.ok>0` and `bytes_received_total >= 500*512*0.95` (full replay) via jq. (Logs go to stderr; capture stdout only.)
- [ ] Step 5: Commit `git add ds-bench/src/catch_up.rs ds-bench/src/main.rs` → `feat(ds-bench): protocol-faithful catch-up stampede workload`.

---

### Task 2: Verify symmetric catch-up vs ursula (fairness gate)

**Files:** none (verification only; may add a note to scripts/smoke-durable.sh comments if helpful — optional).

This confirms ursula's NATIVE catch-up read works with the loop (the symmetry assumption). Use the compose ursula service.

- [ ] Step 1: `docker compose up -d minio && docker compose run --rm minio-init && docker compose up -d ursula`.
- [ ] Step 2: `docker compose run --rm -T bench catch-up --target http://ursula:4437 --api-style ursula --clients 16 --pre-events 500 --event-bytes 512 > /tmp/cu-ursula.json` (note `-T`). Assert `jq '.counts.ok' >0` and `jq '.bytes_received_total'` ≈ `500*512` (≥95%).
- [ ] Step 3: If ursula reads short / errors: diagnose its offset semantics. Capture `curl -s -D - "http://127.0.0.1:4437/<bucket>/doc?offset=-1" -o /dev/null` (and with `?offset=0`) to see which start value ursula accepts and whether it returns `stream-up-to-date`/`stream-next-offset`. If ursula needs `offset=0` (not `-1`) or different headers, adjust `catch_up_start`/header handling in catch_up.rs ONLY (keep it api-style-conditional and symmetric in intent), rebuild, re-verify both durable AND ursula still pass. Document the per-style start value chosen and WHY in the commit + report.
- [ ] Step 4: `docker compose down`. If catch_up.rs changed, commit `fix(ds-bench): ursula-native catch-up offset semantics`. If no change needed, note "ursula accepts offset=-1 and returns DS up-to-date/next-offset headers; symmetric as-is" in the report.

---

### Task 3: orchestration + renderer + README + re-run + refresh comparison

**Files:** Modify `run-bench.sh`, `scripts/render-results.py`, `README.md`.

- [ ] Step 1: run-bench.sh — add catch-up params (identical for both systems): `CU_CLIENTS=200; CU_PRE_EVENTS=2000; CU_EVENT_BYTES=1024`. After the fan-out run, add a third (with `-T`):
```bash
echo "== catch-up =="
run catch-up --target "$TARGET" --api-style "$STYLE" \
  --clients "$CU_CLIENTS" --pre-events "$CU_PRE_EVENTS" --event-bytes "$CU_EVENT_BYTES" \
  > "results/${SYS}-catch-up.json"
```
- [ ] Step 2: render-results.py — add a "catch-up (replay throughput)" section reading `results/{sys}-catch-up.json`: rows for `aggregate_mb_per_sec`, `bytes_received_total`, `stampede_elapsed_secs`, latency p50/p90/p99/p999 (from `latency_ms`), and a `_params: clients=…, pre_events=…, event_bytes=…_` line. Handle a missing file gracefully (like the other sections).
- [ ] Step 3: README.md — update "What is measured" to THREE workloads; describe catch-up as OUR protocol-faithful workload (catch-up read until up-to-date, symmetric, NOT ursula's snapshot bootstrap). Adjust any "two workloads" wording.
- [ ] Step 4: Re-run end-to-end: `./run-bench.sh durable` then `./run-bench.sh ursula` (full, several min). Then `python3 scripts/render-results.py results`. Confirm `results/comparison.md` now has all THREE sections with both columns populated and valid JSON for all 6 result files.
- [ ] Step 5: Commit `git add run-bench.sh scripts/render-results.py README.md` → `feat: add catch-up to orchestration + renderer + docs (3 workloads)`. (results/* stays gitignored.)

---

## Self-Review
- Verbatim integrity: only main.rs (+ new catch_up.rs) changed in ds-bench/src; the 5 forked files byte-identical (Task 1 Step 3). ✓
- Protocol-faithful + symmetric: native per-style read, opaque offset, verified on BOTH servers (Task 2). ✓
- Fairness: identical catch-up params both systems; one server at a time (run-bench unchanged structurally). ✓
- Docs honest: README updated to 3 workloads, catch-up described as ours. ✓
