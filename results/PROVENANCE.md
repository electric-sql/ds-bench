# Provenance — canonical campaign 2026-07-14

**Split build provenance.** The write/durability suites were re-run on the
electric#4710 recovery-hardening build; the rest keep their #4697 values
(#4710 changes no read/ursula/mixed-cal/mixed-writes code path).

- **Write-path suites (`canonical-write`, `canonical-mixed-delivery`):**
  electric-sql/electric#4710 head `abca3a5f7` (fix/recovery-hardening), image
  `durable-streams:dev` digest `93803a261706`. Re-validation of the durability
  hardening — no write regression vs #4697 (wal ±1%, memory flat).
- **All other suites (`canonical-write-ursula`, `canonical-reads-*`,
  `canonical-mixed-cal`, `canonical-mixed-writes`):** electric#4697 head
  `d5589289d` (perf/wal-checkpoint-syncfs), image digest `0e8bfe920065`.
- **Ursula:** upstream `ghcr.io/tonbo-io/ursula:v0.2.0`.
- **Hardware:** canonical-write on `c4d-standard-64-lssd` raw-block (STATIC_CPU=1, GUARANTEED=1, splitlane3x3 manifest); ursula/reads/mixed on `c4d-standard-16-lssd` stock manifests. Clients `n2d-standard-32` Spot. europe-west4.
- **Harness:** ds-bench bench/canonical-suites @ 2b0ada5.
- All suites self-tore-down; zero clusters at campaign end (verified).
