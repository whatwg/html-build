# This Dockerfile is just used to run on Travis CI in an environment that can easily and repeatedly
# install our build dependencies.
FROM debian:stable

RUN apt-get update && \
    apt-get install --yes --no-install-recommends \
    ca-certificates curl rsync git                \
    libfontconfig1 libgomp1 libxml2               \
    default-jre                                   \
    python3 python3-pip                           \
    fonts-dejavu fonts-droid-fallback fonts-liberation fonts-symbola fonts-unfonts-core

# Dependency lines above are:
# - General
# - Prince
# - validator
# - Highlighter
# - fonts, for when Prince renders to PDF

COPY --from=whatwg/wattsi:latest /whatwg/wattsi/bin/wattsi /bin/wattsi
COPY --from=ptspts/pdfsizeopt:latest /bin /bin/pdfsizeopt
RUN pip3 install bs-highlighter

# The DockerHub container for pdfsizeopt has some useful auxiliary binaries it depends on, but the
# main binary is outdated and needs updating directly from GitHub:
# TODO: consolidate these two lines when https://github.com/moby/buildkit/pull/1492 gets released
# (see https://github.com/moby/moby/issues/34819).
ADD https://github.com/pts/pdfsizeopt/blob/master/pdfsizeopt.single?raw=true /bin/pdfsizeopt/pdfsizeopt
RUN chmod a+rwx /bin/pdfsizeopt/pdfsizeopt

# The DockerHub container for the validator only contains the server version, so we get the .jar
# from GitHub:
ADD https://github.com/validator/validator/releases/download/jar/vnu.jar /whatwg/

# Trying to copy Prince from its DockerHub container like the others does not work; it has too many
# shared library dependencies. Additionally, Prince 12 and 13 have bad interactions with pdfsizeopt
# (https://github.com/pts/pdfsizeopt/issues/145, https://github.com/whatwg/html-build/issues/255),
# and Prince 11's .deb file only works with older version of Debian. So, we do it this way (plus the
# manual dependency installations in the apt-get section above).
ADD https://www.princexml.com/download/prince-11.3-linux-generic-x86_64.tar.gz /whatwg/prince.tar.gz
RUN cd /whatwg && \
    tar xzf prince.tar.gz && \
    echo /whatwg/prince | /whatwg/prince-11.3-linux-generic-x86_64/install.sh && \
    echo '@font-face { font-family: serif; src: local("Symbola") }' >> /whatwg/prince/lib/prince/style/fonts.css && \
    rm -rf /whatwg/prince.tar.gz /whatwg/prince-11.3-linux-generic-x86_64

ADD . /whatwg/html-build

ENTRYPOINT ["bash", "/whatwg/html-build/ci-build/inside-container.sh"]
