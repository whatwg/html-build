FROM debian:sid

## dependency installation: apache, wattsi, and other build tools
## enable some apache mods (the ln -s lines)
## cleanup freepascal since it is no longer needed after wattsi build
RUN apt-get update && \
    apt-get install -y python python-dev python-pip python-virtualenv && \
    apt-get install -y ca-certificates curl git unzip fp-compiler-3.0.0 apache2 && \
    cd /etc/apache2/mods-enabled && \
    ln -s ../mods-available/headers.load && \
    ln -s ../mods-available/expires.load && \
    git clone https://github.com/whatwg/wattsi.git /whatwg/wattsi && \
    cd /whatwg/wattsi && \
    /whatwg/wattsi/build.sh && \
    cp /whatwg/wattsi/bin/wattsi /bin/ && \
    apt-get purge -y fp-compiler-3.0.0 && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

ADD . /whatwg/build

ARG html_source_dir
ADD $html_source_dir /whatwg/html
ENV HTML_SOURCE /whatwg/html

WORKDIR /whatwg/build

## build and copy assets to final apache dir

ARG verbose_or_quiet_flag
ARG no_update_flag

# no_update_flag doesn't really work; .cache directory is re-created empty each time
RUN SKIP_BUILD_UPDATE_CHECK=true ./build.sh $verbose_or_quiet_flag $no_update_flag && \
    rm -rf /var/www/html && \
    mv output /var/www/html && \
    chmod -R o+rX /var/www/html && \
    cp site.conf /etc/apache2/sites-available/000-default.conf

CMD ["apache2ctl", "-DFOREGROUND"]
