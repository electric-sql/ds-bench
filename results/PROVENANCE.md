# Provenance — canonical campaign 2026-07-14

- **Server build:** electric-sql/electric#4697 head `d5589289d` (perf/wal-checkpoint-syncfs), image `durable-streams:dev` digest `0e8bfe920065`.
- **Ursula:** upstream `ghcr.io/tonbo-io/ursula:v0.2.0`.
- **Hardware:** canonical-write on `c4d-standard-64-lssd` raw-block (STATIC_CPU=1, GUARANTEED=1, splitlane3x3 manifest); ursula/reads/mixed on `c4d-standard-16-lssd` stock manifests. Clients `n2d-standard-32` Spot. europe-west4.
- **Harness:** ds-bench bench/canonical-suites @ 2b0ada5.
- All suites self-tore-down; zero clusters at campaign end (verified).
