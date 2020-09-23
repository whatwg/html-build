# This Dockerfile is just used to run on Travis CI in an environment that can easily and repeatedly
# install our build dependencies.
FROM debian:stable

RUN apt-get update && \
    apt-get install --yes --no-install-recommends \
    ca-certificates curl rsync git                \
    default-jre                                   \
    python3 python3-pip                           \
    fonts-dejavu fonts-droid-fallback fonts-liberation fonts-symbola fonts-unfonts-core

# Dependency lines above are:
# - General
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
# shared library dependencies. So we get the .deb file from the source:
ADD https://www.princexml.com/download/prince_13.5-1_debian10_amd64.deb .
RUN apt-get install --yes --no-install-recommends ./prince_13.5-1_debian10_amd64.deb && \
    rm prince_13.5-1_debian10_amd64.deb && \
    echo '@font-face { font-family: serif; src: local("Symbola") }' >> /usr/lib/prince/style/fonts.css

ARG html_build_dir
ADD . /whatwg/html-build

# Note: we do not ADD /whatwg/html, but instead mount it in outside-container.html, since it
# contains the deploy_key, and thus should not be part of the image. The image is cached, publicly,
# on Docker Hub.
ENV HTML_SOURCE /whatwg/html

ARG travis_pull_request
ARG is_test_of_html_build_itself
ENV TRAVIS_PULL_REQUEST=${travis_pull_request}
ENV IS_TEST_OF_HTML_BUILD_ITSELF=${is_test_of_html_build_itself}

ENV SKIP_BUILD_UPDATE_CHECK=true
ENTRYPOINT ["bash", "/whatwg/html-build/ci-deploy/inside-container.sh"]
