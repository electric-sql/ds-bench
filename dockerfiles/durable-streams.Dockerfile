# Build context must be the durable-streams repo root (../durable-streams).
# RUST_VERSION is overridable — the `telemetry` feature pulls tonic 0.14 which
# needs rustc >= 1.88; the default production set builds on 1.86.
ARG RUST_VERSION=1.86
FROM rust:${RUST_VERSION}-bookworm AS builder
WORKDIR /src
COPY . .
WORKDIR /src/packages/server-rust
# FEATURES is overridable so a bench/diagnostic image can add `telemetry`
# (WAL_STATS to stdout + per-append OTel timers). Default includes `strict-uring`
# so the `durable:strict-iouring` bench variant exercises the io_uring fsync
# executor (Linux-only; harmless when --strict-io-uring isn't passed).
ARG FEATURES=tier,strict-uring
RUN cargo build --release --features ${FEATURES}
RUN cp target/release/durable-streams-server /durable-streams-server

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /durable-streams-server /usr/local/bin/durable-streams-server
EXPOSE 4438
ENTRYPOINT ["durable-streams-server"]
