FROM debian:stable-slim
RUN apt-get update && \
    apt-get install --yes --no-install-recommends ca-certificates curl git python3 python3-pip pipx && \
    rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/whatwg/wattsi:latest /whatwg/wattsi/bin/wattsi /bin/wattsi

ENV PIPX_HOME /opt/pipx
ENV PIPX_BIN_DIR /usr/bin
RUN pipx install bs-highlighter

COPY . /whatwg/html-build/

ENV SKIP_BUILD_UPDATE_CHECK true
ENTRYPOINT ["bash", "/whatwg/html-build/build.sh"]
