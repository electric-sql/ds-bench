# micro.Dockerfile — durable-streams server + micro benchmark suite
#
# Build context is assembled by scripts/gke-micro.sh (next task), which
# combines the durable-streams server source at the root with this repo's
# micro/ directory alongside it.  DO NOT hardcode cross-repo absolute paths.
#
# Target: linux/amd64 — built via Google Cloud Build (native amd64).

# ---------------------------------------------------------------------------
# Stage 1: build the durable-streams Rust server
# ---------------------------------------------------------------------------
FROM rust:1.86 AS builder
WORKDIR /src
# Build context root = durable-streams checkout, so the crate lives here:
COPY . .
RUN cargo build --release --manifest-path packages/server-rust/Cargo.toml

# ---------------------------------------------------------------------------
# Stage 2: build wrk from source (needs build tools not wanted in runtime)
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS wrk-builder
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        libssl-dev \
        git \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 https://github.com/wg/wrk /tmp/wrk \
    && make -C /tmp/wrk -j \
    && cp /tmp/wrk/wrk /usr/local/bin/wrk

# ---------------------------------------------------------------------------
# Stage 3: lean runtime image
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        python3 \
        procps \
        util-linux \
    && rm -rf /var/lib/apt/lists/*

# MinIO client (mc) — amd64 release binary
RUN curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc \
        -o /usr/local/bin/mc \
    && chmod +x /usr/local/bin/mc

# wrk binary from the wrk-builder stage (no build-essential in runtime)
COPY --from=wrk-builder /usr/local/bin/wrk /usr/local/bin/wrk

# durable-streams server binary from the builder stage
COPY --from=builder /src/target/release/durable-streams-server \
        /usr/local/bin/durable-streams-server

# micro benchmark suite (present in build context assembled by gke-micro.sh)
COPY micro/ /micro/

WORKDIR /micro

ENV BIN=/usr/local/bin/durable-streams-server
ENV DATA=/data

ENTRYPOINT ["bash", "run.sh"]
