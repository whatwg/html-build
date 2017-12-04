#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
cd "$(dirname "$0")/../.."

PDF_SOURCE_URL="https://html.spec.whatwg.org/"
WEB_ROOT="html.spec.whatwg.org"
DEPLOY_USER="annevankesteren"

SERVER="75.119.197.251"
SERVER_PUBLIC_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDP7zWfhJdjre9BHhfOtN52v6kIaDM/1kEJV4HqinvLP2hzworwNBmTtAlIMS2JJzSiE+9WcvSbSqmw7FKmNVGtvCd/CNJJkdAOEzYFBntYLf4cwNozCRmRI0O0awTaekIm03pzLO+iJm0+xmdCjIJNDW1v8B7SwXR9t4ElYNfhYD4HAT+aP+qs6CquBbOPfVdPgQMar6iDocAOQuBFBaUHJxPGMAG0qkVRJSwS4gi8VIXNbFrLCCXnwDC4REN05J7q7w90/8/Xjt0q+im2sBUxoXcHAl38ZkHeFJry/He2CiCc8YPoOAWmM8Vd0Ukc4SYZ99UfW/bxDroLHobLQ9Eh"

# New server, see https://github.com/whatwg/misc-server/issues/7
NEW_SERVER="165.227.248.76"
NEW_SERVER_PUBLIC_KEY="ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBDt6Igtp73aTOYXuFb8qLtgs80wWF6cNi3/AItpWAMpX3PymUw7stU7Pi+IoBJz21nfgmxaKp3gfSe2DPNt06l8="

HTML_SHA=$(git -C html rev-parse HEAD)

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
java -jar vnu.jar --skip-non-html "$HTML_OUTPUT"
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
rsync --rsh="ssh -o UserKnownHostsFile=known_hosts" \
      --archive --compress --delete --verbose --exclude="commit-snapshots" --exclude="*.cgi" \
      "$HTML_OUTPUT/" "$DEPLOY_USER@$SERVER:$WEB_ROOT"

# Now sync a commit snapshot
# (See https://github.com/whatwg/html-build/issues/97 potential improvements to commit snapshots.)
echo ""
echo "Deploying commit snapshot..."
rsync --rsh="ssh -o UserKnownHostsFile=known_hosts" \
      --archive --compress --verbose \
      "$HTML_OUTPUT/index.html" "$DEPLOY_USER@$SERVER:$WEB_ROOT/commit-snapshots/$HTML_SHA"

# Deploy everything to the new server as well.
echo "$NEW_SERVER $NEW_SERVER_PUBLIC_KEY" >> known_hosts

echo ""
echo "Deploying build output to new server..."
rsync --rsh="ssh -o UserKnownHostsFile=known_hosts" \
      --archive --compress --delete --verbose --exclude="commit-snapshots" --exclude="*.cgi" \
      "$HTML_OUTPUT" "deploy@$NEW_SERVER:/var/www/$WEB_ROOT"

echo ""
echo "Deploying commit snapshot to new server..."
rsync --rsh="ssh -o UserKnownHostsFile=known_hosts" \
      --archive --compress --verbose \
      "$HTML_OUTPUT/index.html" "deploy@$NEW_SERVER:/var/www/$WEB_ROOT/commit-snapshots/$HTML_SHA"

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
      "$HTML_OUTPUT/print.pdf" "$DEPLOY_USER@$SERVER:$WEB_ROOT/print.pdf"

echo ""
echo "Deploying PDF to new server..."
rsync --rsh="ssh -o UserKnownHostsFile=known_hosts" \
      --archive --compress --verbose \
      "$HTML_OUTPUT/print.pdf" "deploy@$NEW_SERVER:/var/www/$WEB_ROOT/print.pdf"
# TODO: deploy PDF to the new server as well

echo ""
echo "All done!"
