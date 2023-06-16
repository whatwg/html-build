#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# cd to the directory containing this script
cd "$(dirname "$0")"
DIR=$(pwd)

# The latest required version of Wattsi. Update this if you change how ./build.sh invokes Wattsi;
# it will cause a warning if Wattsi's self-reported version is lower. Note that there's no need to
# update this on every revision of Wattsi; only do so when a warning is justified.
WATTSI_LATEST=136

# Shared state variables throughout this script
LOCAL_WATTSI=true
DO_UPDATE=true
DO_LINT=true
DO_HIGHLIGHT=true
SINGLE_PAGE_ONLY=false
USE_DOCKER=false
VERBOSE=false
QUIET=false
SERVE=false
HTML_SHA=""
HIGHLIGHT_SERVER_PID=""

# Can be set from the outside to customize the script, but the defaults are usually fine. (Only
# $HTML_SOURCE is documented.) $HTML_SOURCE will be determined inside the main function.
HTML_SOURCE=${HTML_SOURCE:-}
HTML_CACHE=${HTML_CACHE:-$DIR/.cache}
HTML_TEMP=${HTML_TEMP:-$DIR/.temp}
HTML_OUTPUT=${HTML_OUTPUT:-$DIR/output}
HTML_GIT_CLONE_OPTIONS=${HTML_GIT_CLONE_OPTIONS:-"--depth=2"}

# These are used by child scripts, and so we export them
export HTML_CACHE
export HTML_TEMP

# Used specifically when the Dockerfile calls this script
SKIP_BUILD_UPDATE_CHECK=${SKIP_BUILD_UPDATE_CHECK:-false}
SHA_OVERRIDE=${SHA_OVERRIDE:-}
BUILD_SHA_OVERRIDE=${BUILD_SHA_OVERRIDE:-}

# This needs to be coordinated with the bs-highlighter package
HIGHLIGHT_SERVER_URL="http://127.0.0.1:8080"

SERVE_PORT=8080

function main {
  processCommandLineArgs "$@"

  # $SKIP_BUILD_UPDATE_CHECK is set inside the Dockerfile so that we don't check for updates both inside and outside
  # the Docker container.
  if [[ $DO_UPDATE == "true" && $SKIP_BUILD_UPDATE_CHECK != "true" ]]; then
    checkHTMLBuildIsUpToDate
  fi

  findHTMLSource

  clearDir "$HTML_OUTPUT"
  # Set these up so rsync will not complain about either being missing
  mkdir -p "$HTML_OUTPUT/commit-snapshots"
  mkdir -p "$HTML_OUTPUT/review-drafts"

  clearCacheIfNecessary

  if [[ $USE_DOCKER == "true" ]]; then
    doDockerBuild
    exit 0
  fi

  checkWattsi
  ensureHighlighterInstalled

  HTML_GIT_DIR="$HTML_SOURCE/.git/"
  HTML_SHA=${SHA_OVERRIDE:-$(git --git-dir="$HTML_GIT_DIR" rev-parse HEAD)}

  doLint

  updateRemoteDataFiles

  startHighlightServer

  processSource "source" "default"

  if [[ -e "$HTML_GIT_DIR" ]]; then
    # This is based on https://github.com/whatwg/whatwg.org/pull/201 and should be kept synchronized
    # with that.
    CHANGED_FILES=$(git --git-dir="$HTML_GIT_DIR" diff --name-only HEAD^ HEAD)
    for CHANGED in $CHANGED_FILES; do # Omit quotes around variable to split on whitespace
      if ! [[ "$CHANGED" =~ ^review-drafts/.*.wattsi$ ]]; then
        continue
      fi
      processSource "$CHANGED" "review"
    done
  else
    echo ""
    echo "Skipping review draft production as the .git directory is not present"
    echo "(This always happens if you use the --docker option.)"
  fi

  $QUIET || echo
  $QUIET || echo "Success!"

  if [[ $SERVE == "true" ]]; then
    stopHighlightServer
    cd "$HTML_OUTPUT"
    python3 -m http.server "$SERVE_PORT"
  fi
}

# Processes incoming command-line arguments
# Arguments: all arguments to this shell script
# Output:
# - If the clean or help commands are given, perform them
# - Otherwise, sets the $DO_UPDATE, $USE_DOCKER, $QUIET, and $VERBOSE variables appropriately
function processCommandLineArgs {
  for arg in "$@"
  do
    case $arg in
      clean)
        clearDir "$HTML_CACHE"
        exit 0
        ;;
      --help|help)
        echo "Commands:"
        echo "  $0        Build the HTML Standard."
        echo "  $0 clean  Remove downloaded dependencies and generated files (then stop)."
        echo "  $0 help   Show this usage statement."
        echo
        echo "Build options:"
        echo "  -d|--docker       Use Docker to build in a container."
        echo "  -s|--serve        After building, serve the results on http://localhost:$SERVE_PORT."
        echo "  -n|--no-update    Don't update before building; just build."
        echo "  -l|--no-lint      Don't lint before building; just build."
        echo "  -h|--no-highlight Don't syntax-highlight the output."
        echo "  -p|--single-page  Only build the single-page variant of the spec."
        echo "  -f|--fast         Alias for --no-update --no-lint --no-highlight --single-page."
        echo "  -q|--quiet        Don't emit any messages except errors/warnings."
        echo "  -v|--verbose      Show verbose output from every build step."
        exit 0
        ;;
      -n|--no-update|--no-updates)
        DO_UPDATE=false
        ;;
      -l|--no-lint)
        DO_LINT=false
        ;;
      -h|--no-highlight)
        DO_HIGHLIGHT=false
        ;;
      -p|--single-page)
        SINGLE_PAGE_ONLY=true
        ;;
      -f|--fast)
        DO_UPDATE=false
        DO_LINT=false
        DO_HIGHLIGHT=false
        SINGLE_PAGE_ONLY=true
        ;;
      -d|--docker)
        USE_DOCKER=true
        ;;
      -q|--quiet)
        QUIET=true
        VERBOSE=false
        ;;
      -v|--verbose)
        VERBOSE=true
        QUIET=false
        set -vx
        ;;
      -s|--serve)
        SERVE=true
        ;;
      *)
        ;;
    esac
  done
}

# Checks if the html-build repository is up to date
# Arguments: none
# Output: will tell the user and exit the script with code 1 if not up to date
function checkHTMLBuildIsUpToDate {
  $QUIET || echo "Checking if html-build is up to date..."
  GIT_FETCH_ARGS=()
  if ! $VERBOSE ; then
    GIT_FETCH_ARGS+=( --quiet )
  fi
  # TODO: `git remote get-url origin` is nicer, but new in Git 2.7.
  ORIGIN_URL=$(git config --get remote.origin.url)
  GIT_FETCH_ARGS+=( "$ORIGIN_URL" main)
  git fetch "${GIT_FETCH_ARGS[@]}"
  NEW_COMMITS=$(git rev-list --count HEAD..FETCH_HEAD)
  if [[ $NEW_COMMITS != "0" ]]; then
    $QUIET || echo
    echo -n "Your local branch is $NEW_COMMITS "
    [[ $NEW_COMMITS == "1" ]] && echo -n "commit" || echo -n "commits"
    echo " behind $ORIGIN_URL:"
    git log --oneline HEAD..FETCH_HEAD
    echo
    echo "To update, run this command:"
    echo
    echo "  git pull --rebase origin main"
    echo
    echo "This check can be bypassed with the --no-update option."
    exit 1
  fi
}

# Tries to install the bs-highlighter Python package if necessary
# - Arguments: none
# - Output:
#   - Either bs-highlighter-server will be in the $PATH, or $DO_HIGHTLIGHT will be set to false and
#     a warning will be echoed.
function ensureHighlighterInstalled {
  # If we're not using local Wattsi then we won't use the local highlighter.
  if [[ $LOCAL_WATTSI == "true" && $DO_HIGHLIGHT == "true" ]]; then
    if hash pipx 2>/dev/null; then
      if ! hash bs-highlighter-server 2>/dev/null; then
        pipx install bs-highlighter
      fi
    else
      echo
      echo "Warning: could not find pipx in your PATH. Disabling syntax highlighting."
      echo
      DO_HIGHLIGHT="false"
    fi
  fi
}

# Runs the lint.sh script, if requested
# - Arguments: none
# - Output:
#   - Will echo any errors and exit the script with error code 1 if lint fails.
function doLint {
  if [[ $DO_LINT == "false" ]]; then
    return
  fi

  $QUIET || echo "Linting the source file..."
  ./lint.sh "$HTML_SOURCE/source" || {
    echo
    echo "There were lint errors. Stopping."
    exit 1
  }
}

# Finds the location of the HTML Standard, and stores it in the HTML_SOURCE variable.
# It either guesses based on directory structure, or interactively prompts the user.
# - Arguments: none
# - Output:
#   - Sets $HTML_SOURCE
function findHTMLSource {
  $QUIET || echo "Looking for the HTML source (set HTML_SOURCE to override)..."
  if [[ $HTML_SOURCE == "" ]]; then
    PARENT_DIR=$(dirname "$DIR")
    if [[ -f "$PARENT_DIR/html/source" ]]; then
      HTML_SOURCE=$PARENT_DIR/html
      $QUIET || echo "Found $HTML_SOURCE (alongside html-build)..."
    else
      if [[ -f "$DIR/html/source" ]]; then
        HTML_SOURCE=$DIR/html
        $QUIET || echo "Found $HTML_SOURCE (inside html-build)..."
      else
        $QUIET || echo "Didn't find the HTML source on your system..."
        chooseRepo
      fi
    fi
  else
    if [[ -f "$HTML_SOURCE/source" ]]; then
      $QUIET || echo "Found $HTML_SOURCE (from HTML_SOURCE)..."
    else
      $QUIET || echo "Looked in the $HTML_SOURCE directory but didn't find HTML source there..."
      HTML_SOURCE=""
      chooseRepo
    fi
  fi

  export HTML_SOURCE
}

# Interactively prompts the user for where their HTML source file is.
# - Arguments: none
# - Output:
#   - Sets $HTML_SOURCE
function chooseRepo {
  echo
  echo "What HTML source would you like to build from?"
  echo
  echo "1) Use an existing clone on my local filesystem."
  echo "2) Create a clone from https://github.com/whatwg/html."
  echo "3) Create a clone from an existing fork, by GitHub username."
  echo "4) Create a clone from an existing fork, by custom URL."
  echo "5) Quit"
  echo
  read -r -e -p "Choose 1-5: " choice
  if [[ $choice == "1" ]]; then
    read -r -e -p "Path to your existing clone: "
    HTML_SOURCE=$(echo "$REPLY" | xargs) # trims leading/trailing space
    if [[ $HTML_SOURCE = "" ]]; then
      chooseRepo
    fi
    confirmRepo
  elif [[ $choice == "2" ]]; then
    HTML_REPO=https://github.com/whatwg/html.git
    confirmRepo
  elif [[ $choice == "3" ]]; then
    echo
    read -r -e -p "GitHub username of fork owner: "
    GH_USERNAME=$(echo "$REPLY" | xargs) # trims leading/trailing space
    if [[ $GH_USERNAME == "" ]]; then
      chooseRepo
    fi
    echo
    echo "Does a fork already exist at https://github.com/$GH_USERNAME/html?"
    echo
    read -r -e -p "Y or N? " yn
    if [[ $yn == "y" || $yn == "Y" ]]; then
      HTML_REPO="https://github.com/$GH_USERNAME/html.git"
      confirmRepo
    else
      echo
      echo "Before proceeding, first go to https://github.com/whatwg/html and create a fork."
      exit
    fi
  elif [[ $choice == "4" ]]; then
    echo
    read -r -e -p "URL: "
    REPLY=$(echo "$REPLY" | xargs) # trims leading/trailing space
    if [[ $REPLY == "" ]]; then
      chooseRepo
    fi
    HTML_REPO=$REPLY
    confirmRepo
  elif [[ $choice == "5" || $choice == "q" || $choice == "Q" ]]; then
    echo
    echo "Can't build without a source repo to build from. Quitting..."
    exit
  else
    chooseRepo
  fi
}

# Confirms the currently-set HTML_SOURCE with the user, or clones HTML_REPO into HTML_SOURCE
# - Arguments: none
# - Output:
#   - $HTML_SOURCE will now point to a folder containing the HTML Standard
function confirmRepo {
  if [[ $HTML_SOURCE != "" ]]; then
    if [[ -f "$HTML_SOURCE/source" ]]; then
      echo
      echo "OK, build from the $HTML_SOURCE/source file?"
      echo
      read -r -e -p "Y or N? " yn
      if [[ $yn == "y" || $yn == "Y" ]]; then
        return
      else
        HTML_SOURCE=""
        chooseRepo
      fi
    else
      echo
      echo "$HTML_SOURCE/source file doesn't exist. Please choose another option."
      HTML_SOURCE=""
      chooseRepo
    fi
    return
  fi
  HTML_SOURCE=${HTML_SOURCE:-$DIR/html}
  echo
  echo "OK, clone from $HTML_REPO?"
  echo
  read -r -e -p "Y or N? " yn
  GIT_CLONE_ARGS=( "$HTML_GIT_CLONE_OPTIONS" )
  if $VERBOSE; then
    GIT_CLONE_ARGS+=( --verbose )
  elif $QUIET; then
    GIT_CLONE_ARGS+=( --quiet )
  fi
  GIT_CLONE_ARGS+=( "$HTML_REPO" "$HTML_SOURCE" )
  if [[ $yn == "y" || $yn == "Y" ]]; then
    git clone "${GIT_CLONE_ARGS[@]}"
  else
    HTML_SOURCE=""
    chooseRepo
  fi
}

# Gives the relative path to $2 from $1
# From http://stackoverflow.com/a/12498485
# - Arguments:
#   - $1: absolute path beginning with /
#   - $2: absolute path beginning with /
# - Output:
#   - Echoes the relative path
function relativePath {
  local source=$1
  local target=$2

  local commonPart=$source
  local result=""

  while [[ "${target#"$commonPart"}" == "${target}" ]]; do
    # no match, means that candidate common part is not correct
    # go up one level (reduce common part)
    commonPart=$(dirname "$commonPart")
    # and record that we went back, with correct / handling
    if [[ $result == "" ]]; then
      result=".."
    else
      result="../$result"
    fi
  done

  if [[ $commonPart == "/" ]]; then
    # special case for root (no common path)
    result="$result/"
  fi

  # since we now have identified the common part,
  # compute the non-common part
  local forwardPart="${target#"$commonPart"}"

  # and now stick all parts together
  if [[ $result != "" ]] && [[ $forwardPart != "" ]]; then
    result="$result$forwardPart"
  elif [[ $forwardPart != "" ]]; then
    # extra slash removal
    result="${forwardPart:1}"
  fi

  echo "$result"
}

# Performs the build using Docker, essentially running this script again inside the container.
# Arguments: none
# Output: A web server with the build output will be running inside the Docker container
function doDockerBuild {
  # Ensure ghcr.io/whatwg/wattsi:latest is up to date. Without this, the locally cached copy would
  # be used, i.e. once Wattsi was downloaded once, it would never update. Note that this is fast
  # (zero-transfer) if the locally cached copy is already up to date.
  DOCKER_PULL_ARGS=()
  $QUIET && DOCKER_PULL_ARGS+=( --quiet )
  DOCKER_PULL_ARGS+=( ghcr.io/whatwg/wattsi:latest )
  docker pull "${DOCKER_PULL_ARGS[@]}"

  DOCKER_BUILD_ARGS=( --tag whatwg-html )
  $QUIET && DOCKER_BUILD_ARGS+=( --quiet )
  docker build "${DOCKER_BUILD_ARGS[@]}" .

  DOCKER_RUN_ARGS=()
  $SERVE && DOCKER_RUN_ARGS+=( --publish "$SERVE_PORT:$SERVE_PORT" )
  DOCKER_RUN_ARGS+=( whatwg-html )
  $QUIET && DOCKER_RUN_ARGS+=( --quiet )
  $VERBOSE && DOCKER_RUN_ARGS+=( --verbose )
  $DO_UPDATE || DOCKER_RUN_ARGS+=( --no-update )
  $DO_LINT || DOCKER_RUN_ARGS+=( --no-lint )
  $DO_HIGHLIGHT || DOCKER_RUN_ARGS+=( --no-highlight )
  $SINGLE_PAGE_ONLY && DOCKER_RUN_ARGS+=( --single-page )
  $SERVE && DOCKER_RUN_ARGS+=( --serve )

  # Pass in the html-build SHA (since there's no .git directory inside the container)
  docker run --rm --interactive --tty \
             --env "BUILD_SHA_OVERRIDE=$(git rev-parse HEAD)" \
             --mount "type=bind,source=$HTML_SOURCE,destination=/whatwg/html-build/html,readonly=1" \
             --mount "type=bind,source=$HTML_CACHE,destination=/whatwg/html-build/.cache" \
             --mount "type=bind,source=$HTML_OUTPUT,destination=/whatwg/html-build/output" \
             "${DOCKER_RUN_ARGS[@]}"
}

# Clears the $HTML_CACHE directory if the build tools have been updated since last run.
# Arguments: none
# Output:
# - $HTML_CACHE will be usable (possibly empty)
function clearCacheIfNecessary {
  if [[ -d "$HTML_CACHE" ]]; then
    PREV_BUILD_SHA=$( cat "$HTML_CACHE/last-build-sha.txt" 2>/dev/null || echo )
    CURRENT_BUILD_SHA=${BUILD_SHA_OVERRIDE:-$(git rev-parse HEAD)}

    if [[ $PREV_BUILD_SHA != "$CURRENT_BUILD_SHA" ]]; then
      $QUIET || echo "Build tools have been updated since last run; clearing the cache..."
      DO_UPDATE=true
      clearDir "$HTML_CACHE"
      echo "$CURRENT_BUILD_SHA" > "$HTML_CACHE/last-build-sha.txt"
    fi
  else
    mkdir -p "$HTML_CACHE"
  fi
}

# Updates the mdn-spec-links-html.json file, if either $DO_UPDATE is true
# or it is not yet cached.
# Arguments: none
# Output:
# - $HTML_CACHE will contain a usable mdn-spec-links-html.json file
function updateRemoteDataFiles {
  CURL_ARGS=( --retry 2 )
  if ! $VERBOSE; then
    CURL_ARGS+=( --silent )
  fi

  CURL_MDN_SPEC_LINKS_ARGS=( "${CURL_ARGS[@]}" \
    --output "$HTML_CACHE/mdn-spec-links-html.json" -k )

  if [[ $DO_UPDATE == "true" \
      || ! -f "$HTML_CACHE/mdn-spec-links-html.json" ]]; then
    rm -f "$HTML_CACHE/mdn-spec-links-html.json"
    $QUIET || echo "Downloading mdn-spec-links/html.json..."
    curl "${CURL_MDN_SPEC_LINKS_ARGS[@]}" \
      https://raw.githubusercontent.com/w3c/mdn-spec-links/master/html.json
  fi

}

# Performs a build of the HTML source file into the resulting output
# - Arguments:
#   - $1: the filename of the source file within HTML_SOURCE (e.g. "source")
#   - $2: the build type, either "default" or "review"
# - Output:
#   - $HTML_OUTPUT will contain the built files
function processSource {
  clearDir "$HTML_TEMP"

  $QUIET || echo "Pre-processing the source..."
  SOURCE_LOCATION="$1"
  BUILD_TYPE="$2"
  cp -p  entities/out/entities.inc "$HTML_CACHE"
  cp -p  entities/out/entities-dtd.url "$HTML_CACHE"
  if $VERBOSE; then
    perl .pre-process-main.pl --verbose < "$HTML_SOURCE/$SOURCE_LOCATION" > "$HTML_TEMP/source-expanded-1"
  else
    perl .pre-process-main.pl < "$HTML_SOURCE/$SOURCE_LOCATION" > "$HTML_TEMP/source-expanded-1"
  fi
  perl .pre-process-annotate-attributes.pl < "$HTML_TEMP/source-expanded-1" > "$HTML_TEMP/source-expanded-2" # this one could be merged
  perl .pre-process-tag-omission.pl < "$HTML_TEMP/source-expanded-2" | perl .pre-process-index-generator.pl > "$HTML_TEMP/source-whatwg-complete" # this one could be merged

  runWattsi "$HTML_TEMP/source-whatwg-complete" "$HTML_TEMP/wattsi-output" "$HIGHLIGHT_SERVER_URL"
  if [[ $WATTSI_RESULT == "0" ]]; then
    if [[ $LOCAL_WATTSI != "true" ]]; then
      "$QUIET" || grep -v '^$' "$HTML_TEMP/wattsi-output.txt" # trim blank lines
    fi
  else
    if [[ $LOCAL_WATTSI != "true" ]]; then
      "$QUIET" || grep -v '^$' "$HTML_TEMP/wattsi-output.txt" # trim blank lines
    fi
    if [[ $WATTSI_RESULT == "65" ]]; then
      echo
      echo "There were errors. Running again to show the original line numbers."
      echo
      runWattsi "$HTML_SOURCE/$SOURCE_LOCATION" "$HTML_TEMP/wattsi-raw-source-output" "$HIGHLIGHT_SERVER_URL"
      if [[ $LOCAL_WATTSI != "true" ]]; then
        grep -v '^$' "$HTML_TEMP/wattsi-output.txt" # trim blank lines
      fi
    fi
    echo
    echo "There were errors. Stopping."
    exit "$WATTSI_RESULT"
  fi

  if [[ $BUILD_TYPE == "default" ]]; then
    # Singlepage HTML
    mv "$HTML_TEMP/wattsi-output/index-html" "$HTML_OUTPUT/index.html"

    if [[ $SINGLE_PAGE_ONLY == "false" ]]; then
      # Singlepage Commit Snapshot
      COMMIT_DIR="$HTML_OUTPUT/commit-snapshots/$HTML_SHA"
      mkdir -p "$COMMIT_DIR"
      mv "$HTML_TEMP/wattsi-output/index-snap" "$COMMIT_DIR/index.html"

      # Multipage HTML and Dev Edition
      mv "$HTML_TEMP/wattsi-output/multipage-html" "$HTML_OUTPUT/multipage"
      mv "$HTML_TEMP/wattsi-output/multipage-dev" "$HTML_OUTPUT/dev"

      cp -pR "$HTML_SOURCE/dev" "$HTML_OUTPUT"
    fi

    cp -p  entities/out/entities.json "$HTML_OUTPUT"
    cp -p "$HTML_TEMP/wattsi-output/xrefs.json" "$HTML_OUTPUT"

    clearDir "$HTML_TEMP"

    echo "User-agent: *
Disallow: /commit-snapshots/
Disallow: /review-drafts/" > "$HTML_OUTPUT/robots.txt"
    cp -p  "$HTML_SOURCE/404.html" "$HTML_OUTPUT"
    cp -p "$HTML_SOURCE/link-fixup.js" "$HTML_OUTPUT"
    cp -p "$HTML_SOURCE/html-dfn.js" "$HTML_OUTPUT"
    cp -p "$HTML_SOURCE/styles.css" "$HTML_OUTPUT"
    cp -pR "$HTML_SOURCE/fonts" "$HTML_OUTPUT"
    cp -pR "$HTML_SOURCE/images" "$HTML_OUTPUT"
    cp -pR "$HTML_SOURCE/demos" "$HTML_OUTPUT"
  else
    # Singlepage Review Draft
    YEARMONTH=$(basename "$SOURCE_LOCATION" .wattsi)
    NEWDIR="$HTML_OUTPUT/review-drafts/$YEARMONTH"
    mkdir -p "$NEWDIR"
    mv "$HTML_TEMP/wattsi-output/index-review" "$NEWDIR/index.html"
  fi
}

# Checks if Wattsi is available and up to date
# - Arguments: none
# - Output:
#   - Sets $LOCAL_WATTSI to true or false
#   - Echoes a warning if Wattsi is out of date according to $WATTSI_LATEST
function checkWattsi {
  if hash wattsi 2>/dev/null; then
    if [[ "$(wattsi --version | cut -d' ' -f2)" -lt "$WATTSI_LATEST" ]]; then
      echo
      echo "Warning: Your wattsi version is out of date. You should to rebuild an"
      echo "up-to-date wattsi binary from the wattsi sources."
      echo
    fi
    LOCAL_WATTSI=true
  else
    LOCAL_WATTSI=false
  fi
}

# Runs Wattsi on the given file, either locally or using the web service
# - Arguments:
#   - $1: the file to run Wattsi on
#   - $2: the directory for Wattsi to write output to
#   - $3: the URL for the syntax-highlighter server
# - Output:
#   - Sets $WATTSI_RESULT to the exit code
#   - $HTML_TEMP/wattsi-output directory will contain the output from Wattsi on success
#   - $HTML_TEMP/wattsi-output.txt will contain the output from Wattsi, on both success and failure
function runWattsi {
  clearDir "$2"

  if [[ "$LOCAL_WATTSI" == "true" ]]; then
    WATTSI_ARGS=()
    if [[ "$QUIET" == "true" ]]; then
      WATTSI_ARGS+=( --quiet )
    fi
    if [[ "$SINGLE_PAGE_ONLY" == "true" ]]; then
      WATTSI_ARGS+=( --single-page-only )
    fi
    WATTSI_ARGS+=( "$1" "$HTML_SHA" "$2" "$BUILD_TYPE" \
      "$HTML_CACHE/mdn-spec-links-html.json" )
    if [[ "$DO_HIGHLIGHT" == "true" ]]; then
      WATTSI_ARGS+=( "$HIGHLIGHT_SERVER_URL" )
    fi

    WATTSI_RESULT="0"
    wattsi "${WATTSI_ARGS[@]}" || WATTSI_RESULT=$?
  else
    $QUIET || echo
    $QUIET || echo "Local wattsi not present; trying the build server..."

    CURL_URL="https://build.whatwg.org/wattsi"
    if [[ "$QUIET" == "true" && "$SINGLE_PAGE_ONLY" == "true" ]]; then
      CURL_URL="$CURL_URL?quiet&single-page-only"
    elif [[ "$QUIET" == "true" ]]; then
      CURL_URL="$CURL_URL?quiet"
    elif [[ "$SINGLE_PAGE_ONLY" == "true" ]]; then
      CURL_URL="$CURL_URL?single-page-only"
    fi

    CURL_ARGS=( "$CURL_URL" \
                --form "source=@$1" \
                --form "sha=$HTML_SHA" \
                --form "build=$BUILD_TYPE" \
                --form "mdn=@$HTML_CACHE/mdn-spec-links-html.json" \
                --dump-header "$HTML_TEMP/wattsi-headers.txt" \
                --output "$HTML_TEMP/wattsi-output.zip" )
    if [[ "$VERBOSE" == "true" ]]; then
      CURL_ARGS+=( --verbose )
    elif [[ "$QUIET" == "true" ]]; then
      CURL_ARGS+=( --silent )
    fi
    curl "${CURL_ARGS[@]}"

    # read exit code from the Wattsi-Exit-Code header and assume failure if not found
    WATTSI_RESULT=1
    while IFS=":" read -r NAME VALUE; do
      shopt -s nocasematch
      if [[ $NAME == "Wattsi-Exit-Code" ]]; then
        WATTSI_RESULT=$(echo "$VALUE" | tr -d ' \r\n')
        break
      fi
      shopt -u nocasematch
    done < "$HTML_TEMP/wattsi-headers.txt"

    if [[ $WATTSI_RESULT != "0" ]]; then
      mv "$HTML_TEMP/wattsi-output.zip" "$HTML_TEMP/wattsi-output.txt"
    else
      UNZIP_ARGS=()
      # Note: Don't use the -v flag; it doesn't work in combination with -d
      if ! $VERBOSE; then
        UNZIP_ARGS+=( -qq )
      fi
      UNZIP_ARGS+=( "$HTML_TEMP/wattsi-output.zip" -d "$2" )
      unzip "${UNZIP_ARGS[@]}"
      mv "$2/output.txt" "$HTML_TEMP/wattsi-output.txt"
    fi
  fi
}

# Starts the syntax-highlighting Python server, when appropriate
# Arguments: none
# Output: if the server is necessary, then
# - A server will be running in the background, at $HIGHLIGHT_SERVER_URL
# - $HIGHLIGHT_SERVER_PID will be set for later use by stopHighlightServer
function startHighlightServer {
  if [[ "$LOCAL_WATTSI" == "true" && "$DO_HIGHLIGHT" == "true" ]]; then
    HIGHLIGHT_SERVER_ARGS=()
    $QUIET && HIGHLIGHT_SERVER_ARGS+=( --quiet )
    bs-highlighter-server ${HIGHLIGHT_SERVER_ARGS[@]+"${HIGHLIGHT_SERVER_ARGS[@]}"} &
    HIGHLIGHT_SERVER_PID=$!

    trap stopHighlightServer EXIT
  fi
}

# Stops the syntax-highlighting Python server
# Arguments: none
# Output: the server will be stopped, if it is running. Failures to stop will be suppressed.
function stopHighlightServer {
  if [[ $HIGHLIGHT_SERVER_PID != "" ]]; then
    kill "$HIGHLIGHT_SERVER_PID" 2>/dev/null || true

    # This suppresses a 'Terminated: 15 "$DIR/highlighter/server.py"' message
    wait "$HIGHLIGHT_SERVER_PID" 2>/dev/null || true
  fi
}

# Ensures the given directory exists, but is empty
# Arguments:
# - $1: the directory to clear
# Output: the directory will be empty (but guaranteed to exist)
function clearDir {
  # We use this implementation strategy, instead of `rm -rf`ing the directory, because deleting the
  # directory itself can run into permissions issues, e.g. if the directory is open in another
  # program, or in the Docker case where we have permission to write to the directory but not delete
  # it.
  mkdir -p "$1"
  find "$1" -mindepth 1 -delete
}

main "$@"
