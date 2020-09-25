#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
shopt -s extglob

TMP_DIR=$(mktemp -d)

function main {
  local here
  here=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )

  # We want the image to contain:
  # * All of the important stuff from the top-level (html-build) directory
  # * But, the Dockerfile from this (ci-build) directory
  # And in particular it should *not* contain the top-level Dockerfile, non-.pl dotfiles, .git/, and
  # any html/ and output/ directories that might be hanging around from local testing.
  cp "$here/Dockerfile" "$TMP_DIR"
  cd "$here/.."
  cp -r !(.*|html|output|Dockerfile) "$TMP_DIR"
  cp .*.pl "$TMP_DIR"
  cd "$TMP_DIR"
  trap cleanTemp EXIT

  local docker_hub_repo="whatwg/html-build"

  # Build the Docker image, using Docker Hub as a cache. (This will be fast if nothing has changed
  # in html-build or its dependencies).
  docker pull whatwg/wattsi
  docker pull ptspts/pdfsizeopt
  docker pull "$docker_hub_repo" || true
  docker build --cache-from "$docker_hub_repo" --tag "$docker_hub_repo" .
}

function cleanTemp {
  rm -rf "$TMP_DIR"
}

main "$@"
