#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
shopt -s extglob

HTML_SOURCE=$(realpath "$1")
HTML_OUTPUT=$(realpath "$2")

docker run --rm --mount "type=bind,source=$HTML_SOURCE,destination=/whatwg/html,readonly=1" \
                --env "HTML_SOURCE=/whatwg/html" \
                --mount "type=bind,source=$HTML_OUTPUT,destination=/whatwg/output" \
                --env "HTML_OUTPUT=/whatwg/output" \
                whatwg/html-build
