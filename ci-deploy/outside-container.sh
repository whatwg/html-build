#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

HERE=$(dirname "$0")
cd "$HERE/../.."

DOCKER_USERNAME="domenicdenicola"
DOCKER_HUB_REPO="whatwg/html-deploy"

# Set from the outside:
TRAVIS_PULL_REQUEST=${TRAVIS_PULL_REQUEST:-false}
IS_TEST_OF_HTML_BUILD_ITSELF=${IS_TEST_OF_HTML_BUILD_ITSELF:-false}

# When not running pull request builds:
# - DOCKER_PASSWORD is set from the outside
# - ENCRYPTION_LABEL is set from the outside

# Initialize the highlighter submodule for html-build
(
  cd html-build
  git submodule init
  git submodule update
)

git clone --depth 1 https://github.com/whatwg/wattsi.git wattsi

git clone --depth 1 https://github.com/pts/pdfsizeopt.git pdfsizeopt

# Copy the Docker-related stuff into the working (grandparent) directory.
cp "$HERE"/{.dockerignore,Dockerfile} .

# Build the Docker image, using Docker Hub as a cache. (This will be fast if nothing has changed
# in wattsi or html-build).
docker pull "$DOCKER_HUB_REPO:latest"
docker build --cache-from "$DOCKER_HUB_REPO:latest" \
             --tag "$DOCKER_HUB_REPO:latest" \
             --build-arg "travis_pull_request=$TRAVIS_PULL_REQUEST" \
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
docker run --volume "$(pwd)/html":/whatwg/html "$DOCKER_HUB_REPO:latest"

if [[ "$TRAVIS_PULL_REQUEST" == "false" && "$IS_TEST_OF_HTML_BUILD_ITSELF" == "false" ]]; then
  # If the build succeeded and we got here, upload the Docker image to Docker Hub, so that future runs
  # can use it as a cache.
  echo ""
  docker tag "$DOCKER_HUB_REPO:latest" "$DOCKER_HUB_REPO:$TRAVIS_BUILD_NUMBER" &&
  docker login -u "$DOCKER_USERNAME" -p "$DOCKER_PASSWORD"
  docker push "$DOCKER_HUB_REPO"
fi
