FROM debian:stable

## dependency installation: nginx and other build tools
RUN apt-get update && \
    apt-get install -y ca-certificates curl git unzip nginx python3 python3-pip && \
    rm -rf /etc/nginx/sites-enabled/* && \
    rm -rf /var/lib/apt/lists/*

COPY --from=whatwg/wattsi:latest /whatwg/wattsi/bin/wattsi /bin/wattsi

ADD . /whatwg/build

RUN pip3 install bs-highlighter

ARG html_source_dir
ADD $html_source_dir /whatwg/html
ENV HTML_SOURCE /whatwg/html

WORKDIR /whatwg/build

## build and copy assets to final nginx dir

ARG verbose_or_quiet_flag
ARG no_update_flag
ARG sha_override

# no_update_flag doesn't really work; .cache directory is re-created empty each time
RUN SKIP_BUILD_UPDATE_CHECK=true SHA_OVERRIDE=$sha_override \
    ./build.sh $verbose_or_quiet_flag $no_update_flag && \
    rm -rf /var/www/html && \
    mv output /var/www/html && \
    chmod -R o+rX /var/www/html && \
    cp site.conf /etc/nginx/sites-enabled/

CMD ["nginx", "-g", "daemon off;"]
