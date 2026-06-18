# Build context is the ds-bench/ crate directory.
# ds-bench is edition 2024 -> needs Rust >= 1.86.
FROM rust:1.86-bookworm AS builder
WORKDIR /src
COPY . .
RUN cargo build --release
RUN cp target/release/ds-bench /ds-bench

FROM debian:bookworm-slim
# ca-certificates for TLS; `mc` (MinIO client) so the fleet/coordinator can
# upload/download HDR+JSON results to in-cluster MinIO (cross-node merge).
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc \
    && chmod +x /usr/local/bin/mc && rm -rf /var/lib/apt/lists/*
COPY --from=builder /ds-bench /usr/local/bin/ds-bench
ENTRYPOINT ["ds-bench"]
