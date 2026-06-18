# DS-node (Node/TypeScript durable-streams server) — SKIPPED

Task 9 of the Phase-2b.2 plan deploys the Node/TS durable-streams server so it
can join the single-node matrix. **It is SKIPPED.** The plan explicitly allows
this: *"If the Node server is genuinely hard to build/run (no clear entrypoint,
missing tier support), do NOT block the matrix — report DS-node as SKIPPED with
the reason and continue with DS-rust/ursula/S2."*

## Why (evidence from `../durable-streams/packages/server`)

1. **No standalone production entrypoint.** `packages/server` is a *library*,
   not a runnable server. `package.json` has `main: ./dist/index.cjs`, **no
   `bin`**, and scripts are only `build`/`dev`/`typecheck` (no `start`). The
   public type is `DurableStreamTestServer` (`src/server.ts:151`), documented in
   its README as a reference/test implementation: *"For production deployments,
   use the Caddy plugin or Electric Cloud."* Running it requires writing a
   bespoke TS wrapper that imports the class and calls `.start()`.

2. **No S3 / cold-tier / offload support.** `grep` over `packages/server/src`
   finds zero `S3`/`bucket`/`endpoint`/`AWS_`/`minio` references. Storage is
   in-memory (`StreamStore`) or local-disk LMDB (`FileBackedStreamStore`,
   `src/file-store.ts`) only. There is **no way to point it at the in-cluster
   MinIO cold tier** — so it cannot be made apples-to-apples with the other
   systems' *matched single-node durability + object-tier offload*, which is the
   entire fairness premise of this matrix.

3. **No env-based configuration.** Port (`4437` default) and `dataDir` are
   constructor options only; the library reads no `process.env`. A K8s
   Deployment (ConfigMap/env) cannot configure it without the wrapper above.

4. **Heavy monorepo build.** `packages/server` depends on `workspace:*`
   (`@durable-streams/client`, `@durable-streams/state`) under pnpm, so a Docker
   image must check out the whole monorepo and `pnpm install` at the root.

## Protocol note (for the record)

The Node server *does* speak the same HTTP durable-streams protocol as the Rust
server (PUT create / POST append / GET SSE read — `src/server.ts:525`), so
`ds-bench --api-style durable` would talk to it fine. The blocker is purely
operational (no entrypoint, no env config) and substantive (no S3 cold tier →
not durability-matched), not protocol parity.

## Outcome

The single-node matrix runs **DS-rust(1), ursula(1), S2 Lite(1)**. DS-node is
reported SKIPPED in `results-gke/comparison.md` with this reason.
