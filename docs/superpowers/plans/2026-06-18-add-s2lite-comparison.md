# Addendum: add S2 Lite as a third comparison system

> Subagent-driven; checkbox steps. Branch `track1-followups` from `main`.

**Goal:** Add S2 Lite (open-source, self-hostable; `ghcr.io/s2-streamstore/s2`, `s2 lite` subcommand, SlateDB → object store) as a third system in the single-node comparison, driven by ds-bench's existing `--api-style s2`, across all three workloads.

**Decision (user):** Run S2 Lite at its DEFAULT flush against MinIO; DISCLOSE its different durability substrate (write-through to object store) vs durable-streams/ursula (local fsync + async S3 tiering). Not tuned to fake parity.

## Global Constraints
- S2 Lite image `ghcr.io/s2-streamstore/s2`, command `lite --bucket s2-bench --path s2lite --port 80`, env `AWS_ACCESS_KEY_ID=minioadmin`, `AWS_SECRET_ACCESS_KEY=minioadmin`, `AWS_ENDPOINT_URL_S3=http://minio:9000`. Default flush interval (do NOT set SL8_FLUSH_INTERVAL).
- Host port 4439 → container 80. Inside compose, ds-bench targets `http://s2lite:80`.
- ds-bench drives it with `--api-style s2 --basin benchmark`. Do NOT modify ds-bench/src (the s2 backend is already there, verbatim).
- A new MinIO bucket `s2-bench` must be created by minio-init (S2 Lite writes its SlateDB WAL/SSTs there).
- One system at a time during measurement (unchanged). Identical ds-bench workload params across all three systems.
- Honesty: README + comparison must state the three durability substrates; S2's writes take a MinIO round-trip the others don't.

---

### Task 1: s2lite compose service + bucket + local verification

**Files:** Modify `docker-compose.yml`.

- [ ] Step 1: Add `s2-bench` to minio-init's bucket creation (alongside `durable-streams` and `ursula`): `mc mb -p local/s2-bench`.
- [ ] Step 2: Add the `s2lite` service:
```yaml
  s2lite:
    image: ghcr.io/s2-streamstore/s2:latest
    depends_on:
      minio:
        condition: service_healthy
    command: ["lite", "--bucket", "s2-bench", "--path", "s2lite", "--port", "80"]
    environment:
      AWS_ACCESS_KEY_ID: minioadmin
      AWS_SECRET_ACCESS_KEY: minioadmin
      AWS_ENDPOINT_URL_S3: http://minio:9000
    ports:
      - "4439:80"
```
- [ ] Step 3 (verify startup + API shape): `docker compose up -d minio && docker compose run --rm minio-init && docker compose up -d s2lite`; wait/poll `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4439/` until non-000. Confirm the container stays up (`docker compose ps s2lite` → running, not restarting). If the image tag/flags differ from the recipe, inspect `docker run --rm ghcr.io/s2-streamstore/s2:latest lite --help` and adjust the command MINIMALLY; document any change.
- [ ] Step 4 (drive it with ds-bench, all 3 workloads — the gate): build bench if needed; run each against s2lite (note `-T`), short configs:
  - `docker compose run --rm -T bench multi-stream --target http://s2lite:80 --api-style s2 --basin benchmark --streams 8 --duration-secs 5 --payload-bytes 128 > /tmp/s2-ms.json` → assert `jq '.counts.ok' >0`.
  - `docker compose run --rm -T bench fan-out --target http://s2lite:80 --api-style s2 --basin benchmark --subscribers 8 --writer-rate 50 --duration-secs 5 > /tmp/s2-fo.json` → assert `jq '.events_received' >=0` (S2 SSE may be slow; >0 ideal, but record whatever it does — note if 0).
  - `docker compose run --rm -T bench catch-up --target http://s2lite:80 --api-style s2 --basin benchmark --clients 8 --pre-events 200 --event-bytes 256 > /tmp/s2-cu.json` → assert `jq '.counts.ok' >0` and bytes received >0.
  If a workload errors against S2 (e.g. namespace/stream creation 404, or seq_num read semantics differ): capture the response (`curl -i`) and DEBUG only via compose/config or by confirming the S2 API shape with `--help`/docs — do NOT modify ds-bench/src. If a workload genuinely cannot run against S2 Lite, report it as a finding (we'll disclose that S2 lacks that workload), don't fake it.
- [ ] Step 5 (verify offload): `docker compose exec minio mc ls --recursive local/s2-bench | head` → shows S2 Lite's SlateDB objects (WAL/SSTs). Then `docker compose down`.
- [ ] Step 6: Commit `docker-compose.yml` → `feat(compose): add S2 Lite service + s2-bench bucket`. Report which workloads ran cleanly + the offload listing.

---

### Task 2: orchestration + renderer + README + 3-system re-run

**Files:** Modify `run-bench.sh`, `scripts/render-results.py`, `README.md`.

- [ ] Step 1: run-bench.sh — add an `s2` case to the `case "$SYS"` block: `SVC=s2lite; TARGET=http://s2lite:80; STYLE=s2; HOSTPORT=4439`. The s2 api-style needs `--basin benchmark` on every ds-bench call — add a `BASIN_ARG` that is `--basin benchmark` for s2 and empty for others, and pass it to each `run` invocation (or add a per-call `--basin benchmark` only in the s2 path). Keep workload params (STREAMS/DURATION/PAYLOAD/SUBSCRIBERS/WRITER_RATE/CU_*) identical to the other systems. Keep the readiness poll (uses HOSTPORT) and `-T`.
- [ ] Step 2: render-results.py — generalize `SYSTEMS = ["durable", "ursula"]` to include `"s2"` (so all sections render a third column). Confirm the table/`row()`/`first_present()` logic handles three systems (it iterates SYSTEMS, so it should). Make sure a missing s2 file degrades gracefully (shows `-`/0), so the renderer still works if s2 wasn't run.
- [ ] Step 3: README — update "What is measured" / systems list to THREE systems. Add a clear **durability-substrate disclosure**: durable-streams & ursula fsync to local disk on the hot path and offload sealed/cold segments to MinIO asynchronously; **S2 Lite writes through SlateDB to object storage (MinIO) on the write path** (default flush), so its acked writes take a MinIO round-trip the others don't. State that all three point at the same MinIO, single-node, and that this is an architectural difference the benchmark surfaces (not a tuned handicap). Note S2's fan-out is expected slower (SSE not object-store-native).
- [ ] Step 4: Re-run all THREE systems (several minutes): `./run-bench.sh durable && ./run-bench.sh ursula && ./run-bench.sh s2`, then `python3 scripts/render-results.py results`. Confirm 9 result files (3 systems × 3 workloads), all valid JSON, and `results/comparison.md` has 3 sections each with 3 columns. (If an S2 workload produced 0 — e.g. fan-out — leave its cell as the real value and ensure the disclosure mentions it.)
- [ ] Step 5: Commit `run-bench.sh scripts/render-results.py README.md` → `feat: add S2 Lite to orchestration + renderer + docs (3 systems)`. results/* stay gitignored.

---

## Self-Review
- S2 Lite self-hosted via compose against MinIO; ds-bench drives it via the existing verbatim s2 backend (no src changes). ✓
- Identical workload params across all three systems; one server at a time. ✓
- Durability difference DISCLOSED, not hidden or faked. ✓
- Renderer handles 3 systems + missing-file safety. ✓
