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

# Environment variables set from outside
TRAVIS_PULL_REQUEST=${TRAVIS_PULL_REQUEST:-false}

# Build the spec into the output directory
./html-build/build.sh

# Conformance-check the result
echo ""
echo "Downloading and running conformance checker..."
curl --remote-name --fail https://sideshowbarker.net/nightlies/jar/vnu.jar
java -Xmx1g -jar vnu.jar --skip-non-html "$HTML_OUTPUT"
echo ""

# Note: $TRAVIS_PULL_REQUEST is either a number or false, not true or false.
# https://docs.travis-ci.com/user/environment-variables/#Default-Environment-Variables
if [[ "$TRAVIS_PULL_REQUEST" != "false" ]]; then
  echo "Skipping deploy for non-master"
  exit 0
fi

# Add the (decoded) deploy key to the SSH agent, so scp works
chmod 600 html/deploy-key
eval "$(ssh-agent -s)"
ssh-add html/deploy-key
echo "$SERVER $SERVER_PUBLIC_KEY" > known_hosts

# Sync, including deletes, but ignoring the commit-snapshots directory so we don't delete that.
echo "Deploying build output..."
# --chmod=D755,F644 means read-write for user, read-only for others.
rsync --rsh="ssh -o UserKnownHostsFile=known_hosts" \
      --archive --chmod=D755,F644 --compress --verbose \
      --delete --exclude="$COMMITS_DIR" --exclude="$REVIEW_DR" \
      --exclude=print.pdf \
      "$HTML_OUTPUT/" "deploy@$SERVER:/var/www/$WEB_ROOT"

# Now sync a commit snapshot and a review draft, if any
# (See https://github.com/whatwg/html-build/issues/97 potential improvements to commit snapshots.)
echo ""
echo "Deploying commit snapshot..."
# --chmod=D755,F644 means read-write for user, read-only for others.
rsync --rsh="ssh -o UserKnownHostsFile=known_hosts" \
      --archive --chmod=D755,F644 --compress --verbose \
      "$COMMITS_DIR" "$REVIEW_DIR" "deploy@$SERVER:/var/www/$WEB_ROOT"

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
