#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
cd "$(dirname "$0")/../.."

PDF_SERVE_PORT=8080

SKIP_BUILD_UPDATE_CHECK=true ./html-build/build.sh

echo ""
echo "Running conformance checker..."
# the -Xmx1g argument sets the size of the Java heap space to 1 gigabyte
java -Xmx1g -jar ./vnu.jar --skip-non-html "$HTML_OUTPUT"
echo ""

# Serve the built output so that Prince can snapshot it
# The nohup/sleep incantations are necessary because normal & does not work inside Docker:
# https://stackoverflow.com/q/50211207/3191
(
  cd "$HTML_OUTPUT"
  nohup bash -c "python3 -m http.server $PDF_SERVE_PORT &" && sleep 4
)

echo ""
echo "Building PDF..."
PATH=/whatwg/prince/bin:$PATH prince --verbose --output "$HTML_OUTPUT/print.pdf" "http://0.0.0.0:$PDF_SERVE_PORT/"
