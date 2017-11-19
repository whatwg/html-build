# This Dockerfile is just used to run on Travis CI in an environment that can easily and repeatedly
# install our build dependencies.
FROM debian:sid

RUN apt-get update && \
    apt-get install -y ca-certificates curl rsync git unzip fp-compiler default-jre

ADD wattsi /whatwg/wattsi

RUN cd /whatwg/wattsi && \
    /whatwg/wattsi/build.sh
ENV PATH="/whatwg/wattsi/bin:${PATH}"

ADD https://www.princexml.com/download/prince-11.3-linux-generic-x86_64.tar.gz /whatwg/prince.tar.gz

# Dependecies of prince_11.3-1_debian8.0_amd64.deb (not used) are libc6 libcurl3 libfontconfig1
# libfreetype6 libgif4 libgomp1 libjpeg62-turbo libpng12-0 libssl1.0.0 libtiff5 libxml2 zlib1g.
# Install the subset of that that's needed to make prince work and fonts.
RUN apt-get update && apt-get install -y libfontconfig1 libgomp1 libxml2 \
    fonts-dejavu fonts-droid-fallback && \
    cd /whatwg && \
    tar xzf prince.tar.gz && \
    echo | /whatwg/prince-11.3-linux-generic-x86_64/install.sh && \
    rm -rf /whatwg/prince.tar.gz /whatwg/prince-11.3-linux-generic-x86_64

ADD html-build /whatwg/html-build

# Note: we do not ADD /whatwg/html, but instead mount it using --volume in .travis.yml, since it
# contains the deploy_key, and thus should not be part of the image. The image is cached, publicly,
# on Docker Hub.
ENV HTML_SOURCE /whatwg/html

ARG travis_pull_request
ENV TRAVIS_PULL_REQUEST=${travis_pull_request}

ENV SKIP_BUILD_UPDATE_CHECK=true
ENTRYPOINT ["bash", "/whatwg/html-build/ci-deploy/inside-container.sh"]
