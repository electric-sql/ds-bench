# Build context is the ds-bench/ crate directory.
# ds-bench is edition 2024 -> needs Rust >= 1.86.
FROM rust:1.86-bookworm AS builder
WORKDIR /src
COPY . .
RUN cargo build --release
RUN cp target/release/ds-bench /ds-bench

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /ds-bench /usr/local/bin/ds-bench
ENTRYPOINT ["ds-bench"]
