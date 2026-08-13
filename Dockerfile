FROM rust:1.90-slim AS builder
WORKDIR /whatwg/html-build
COPY Cargo.lock Cargo.toml ./
COPY src ./src/
RUN cargo install --path .

FROM debian:stable-slim
RUN apt-get update && \
    apt-get install --yes --no-install-recommends ca-certificates curl git python3 python3-pip pipx && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/cargo/bin/html-build /bin/html-build

COPY --from=ghcr.io/whatwg/wattsi:latest /whatwg/wattsi/bin/wattsi /bin/wattsi

ENV PIPX_HOME=/opt/pipx
ENV PIPX_BIN_DIR=/usr/bin
# Pinned: bs-highlighter 3.x re-escapes "<" as "&lt;" in highlighted IDL blocks, which Wattsi then
# fails to re-parse ('IDL SYNTAX ERROR ... "Promise&lt"'). Unpin once Wattsi handles 3.x output.
RUN pipx install "bs-highlighter==2.0.3"

COPY . /whatwg/html-build/

ENV SKIP_BUILD_UPDATE_CHECK=true
ENTRYPOINT ["bash", "/whatwg/html-build/build.sh"]
