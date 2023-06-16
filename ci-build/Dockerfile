# This Dockerfile is just used to run on Travis CI in an environment that can easily and repeatedly
# install our build dependencies.
FROM debian:stable

RUN apt-get update && \
    apt-get install --yes --no-install-recommends \
    ca-certificates curl rsync git                \
    default-jre                                   \
    python3 python3-pip pipx                      \
    libbrotli1 libexpat1 libfontconfig1 libfreetype6 libpng16-16 \
    fonts-dejavu fonts-droid-fallback fonts-liberation fonts-symbola fonts-unfonts-core

# Dependency lines above are:
# - General
# - validator
# - Highlighter
# - Prince
# - fonts, for when Prince renders to PDF

COPY --from=ghcr.io/whatwg/wattsi:latest /whatwg/wattsi/bin/wattsi /bin/wattsi

ENV PIPX_HOME /opt/pipx
ENV PIPX_BIN_DIR /usr/bin
RUN pipx install bs-highlighter

# The DockerHub container for the validator only contains the server version, so we get the .jar
# from GitHub:
ADD https://github.com/validator/validator/releases/download/latest/vnu.jar /whatwg/

# Trying to copy Prince from its DockerHub container like the others does not work; it has too many
# shared library dependencies. Probably this is a job for Docker Compose... we should learn how that
# works one day.
# Prince also hasn't been updated for Debian 12 and is no longer installable from its deb file.
ADD https://www.princexml.com/download/prince-14.2-linux-generic-x86_64.tar.gz /whatwg/prince.tar.gz
RUN cd /whatwg && \
    tar xvzf prince.tar.gz && \
    ( cd prince-* && echo /usr | ./install.sh ) && \
    echo '@font-face { font-family: serif; src: local("Symbola") }' >> /usr/lib/prince/style/fonts.css && \
    rm -rf prince* && \
    prince --version

ADD . /whatwg/html-build

ENTRYPOINT ["bash", "/whatwg/html-build/ci-build/inside-container.sh"]
