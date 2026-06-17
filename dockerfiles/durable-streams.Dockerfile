# Build context must be the durable-streams repo root (../durable-streams).
FROM rust:1.86-bookworm AS builder
WORKDIR /src
COPY . .
WORKDIR /src/packages/server-rust
RUN cargo build --release --features tier
RUN cp target/release/durable-streams-server /durable-streams-server

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /durable-streams-server /usr/local/bin/durable-streams-server
EXPOSE 4438
ENTRYPOINT ["durable-streams-server"]
