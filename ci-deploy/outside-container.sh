#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
shopt -s extglob

HERE="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
TMP_DIR=$(mktemp -d)

function main {
  cp "$HERE/Dockerfile" "$TMP_DIR"
  cd "$HERE/.."
  cp -r !(.*|html|Dockerfile) "$TMP_DIR"
  cp .*.pl "$TMP_DIR"
  cd "$TMP_DIR"
  trap cleanTemp EXIT

  DOCKER_TAG="whatwg/html-deploy:latest"

  # Set from the outside:
  TRAVIS_PULL_REQUEST=${TRAVIS_PULL_REQUEST:-false}
  IS_TEST_OF_HTML_BUILD_ITSELF=${IS_TEST_OF_HTML_BUILD_ITSELF:-false}

  # When not running pull request builds:
  # - ENCRYPTION_LABEL is set from the outside

  # Build the Docker image, using Docker Hub as a cache. (This will be fast if nothing has changed
  # in wattsi or html-build).
  docker build --tag "$DOCKER_TAG" \
               --build-arg "html_build_dir=$TMP_DIR" \
               --build-arg "travis_pull_request=$TRAVIS_PULL_REQUEST" \
               --build-arg "is_test_of_html_build_itself=$IS_TEST_OF_HTML_BUILD_ITSELF" \
               .
  if [[ "$TRAVIS_PULL_REQUEST" == "false" && "$IS_TEST_OF_HTML_BUILD_ITSELF" == "false" ]]; then
    # Decrypt the deploy key from this script's location into the html/ directory, since that's the
    # directory that will be shared with the container (but not built into the image).
    ENCRYPTED_KEY_VAR="encrypted_${ENCRYPTION_LABEL}_key"
    ENCRYPTED_IV_VAR="encrypted_${ENCRYPTION_LABEL}_iv"
    ENCRYPTED_KEY=${!ENCRYPTED_KEY_VAR}
    ENCRYPTED_IV=${!ENCRYPTED_IV_VAR}
    openssl aes-256-cbc -K "$ENCRYPTED_KEY" -iv "$ENCRYPTED_IV" \
            -in "$HERE/deploy-key.enc" -out html/deploy-key -d
  fi

  # Run the inside-container.sh script, with the html/ directory mounted inside the container.
  echo ""
  cd "$HERE/../.."
  docker run --mount "type=bind,source=$(pwd)/html,destination=/whatwg/html,readonly=1" "$DOCKER_TAG"
}

function cleanTemp {
  rm -rf "$TMP_DIR"
}

main "$@"
