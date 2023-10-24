FROM rust:1.73-slim as builder
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

ENV PIPX_HOME /opt/pipx
ENV PIPX_BIN_DIR /usr/bin
RUN pipx install bs-highlighter

COPY . /whatwg/html-build/

ENV SKIP_BUILD_UPDATE_CHECK true
ENTRYPOINT ["bash", "/whatwg/html-build/build.sh"]
