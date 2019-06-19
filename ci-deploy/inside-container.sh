#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
cd "$(dirname "$0")/../.."

PDF_SOURCE_URL="https://html.spec.whatwg.org/"
WEB_ROOT="html.spec.whatwg.org"
COMMITS_DIR="commit-snapshots"
REVIEW_DIR="review-drafts"

SERVER="165.227.248.76"
SERVER_PUBLIC_KEY="ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBDt6Igtp73aTOYXuFb8qLtgs80wWF6cNi3/AItpWAMpX3PymUw7stU7Pi+IoBJz21nfgmxaKp3gfSe2DPNt06l8="

# `export`ed because build.sh reads it
HTML_OUTPUT="$(pwd)/output"
export HTML_OUTPUT

# Note: $TRAVIS_PULL_REQUEST is either a number or false, not true or false.
# https://docs.travis-ci.com/user/environment-variables/#Default-Environment-Variables
TRAVIS_PULL_REQUEST=${TRAVIS_PULL_REQUEST:-false}
IS_TEST_OF_HTML_BUILD_ITSELF=${IS_TEST_OF_HTML_BUILD_ITSELF:-false}

# Build the spec into the output directory
./html-build/build.sh

# Conformance-check the result
echo ""
echo "Downloading and running conformance checker..."
curl --retry 2 --remote-name --fail --location https://github.com/validator/validator/releases/download/linux/vnu.linux.zip
unzip vnu.linux.zip
./vnu-runtime-image/bin/java -Xmx1g -m vnu/nu.validator.client.SimpleCommandLineValidator --skip-non-html "$HTML_OUTPUT"
echo ""

if [[ "$TRAVIS_PULL_REQUEST" != "false" ]]; then
  echo "Skipping deploy for non-master"
  exit 0
fi
if [[ "$IS_TEST_OF_HTML_BUILD_ITSELF" == "true" ]]; then
  echo "Skipping deploy for html-build testing purposes"
  exit 0
fi

# Add the (decoded) deploy key to the SSH agent, so scp works
chmod 600 html/deploy-key
eval "$(ssh-agent -s)"
ssh-add html/deploy-key
echo "$SERVER $SERVER_PUBLIC_KEY" > known_hosts

# Sync, including deletes, but ignoring the stuff we'll deploy below, so that we don't delete them.
echo "Deploying build output..."
# --chmod=D755,F644 means read-write for user, read-only for others.
rsync --rsh="ssh -o UserKnownHostsFile=known_hosts" \
      --archive --chmod=D755,F644 --compress --verbose \
      --delete --exclude="$COMMITS_DIR" --exclude="$REVIEW_DIR" \
      --exclude=print.pdf \
      "$HTML_OUTPUT/" "deploy@$SERVER:/var/www/$WEB_ROOT"

# Now sync a commit snapshot and a review draft, if any
# (See https://github.com/whatwg/html-build/issues/97 potential improvements to commit snapshots.)
echo ""
echo "Deploying Commit Snapshot and Review Drafts, if any..."
# --chmod=D755,F644 means read-write for user, read-only for others.
rsync --rsh="ssh -o UserKnownHostsFile=known_hosts" \
      --archive --chmod=D755,F644 --compress --verbose \
      "$HTML_OUTPUT/$COMMITS_DIR" "$HTML_OUTPUT/$REVIEW_DIR" "deploy@$SERVER:/var/www/$WEB_ROOT"

echo ""
echo "Building PDF..."
PDF_TMP="$(mktemp --suffix=.pdf)"
prince --verbose --output "$PDF_TMP" "$PDF_SOURCE_URL"

echo ""
echo "Optimizing PDF..."
pdfsizeopt --v=40 "$PDF_TMP" "$HTML_OUTPUT/print.pdf"

echo ""
echo "Deploying PDF..."
rsync --rsh="ssh -o UserKnownHostsFile=known_hosts" \
      --archive --compress --verbose \
      "$HTML_OUTPUT/print.pdf" "deploy@$SERVER:/var/www/$WEB_ROOT/print.pdf"

echo ""
echo "All done!"
