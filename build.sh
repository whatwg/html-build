#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# cd to the directory containing this script
cd "$(dirname "$0")"
DIR=$(pwd)

# The latest required version of Wattsi. Update this and the fallback in
# https://github.com/whatwg/wattsi/blob/master/src/build.sh if you change how ./build.sh invokes
# Wattsi.
WATTSI_LATEST=90

# Shared state variables throughout this script
LOCAL_WATTSI=true
DO_UPDATE=true
USE_DOCKER=false
VERBOSE=false
QUIET=false
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
HIGHLIGHT_SERVER_URL="http://127.0.0.1:8080" # this needs to be coordinated with the bs-highlighter package

function main {
  processCommandLineArgs "$@"

  # $SKIP_BUILD_UPDATE_CHECK is set inside the Dockerfile so that we don't check for updates both inside and outside
  # the Docker container.
  if [[ $DO_UPDATE == "true" && $SKIP_BUILD_UPDATE_CHECK != "true" ]]; then
    checkHTMLBuildIsUpToDate
    # If we're using Docker then this will be installed inside the container.
    if [[ $USE_DOCKER != "true" ]]; then
      pip3 install bs-highlighter
    fi
  fi

  findHTMLSource

  HTML_GIT_DIR="$HTML_SOURCE/.git/"
  HTML_SHA=${SHA_OVERRIDE:-$(git --git-dir="$HTML_GIT_DIR" rev-parse HEAD)}

  if [[ $USE_DOCKER == "true" ]]; then
    doDockerBuild
    exit 0
  fi

  $QUIET || echo "Linting the source file..."
  ./lint.sh "$HTML_SOURCE/source" || {
    echo
    echo "There were lint errors. Stopping."
    exit 1
  }

  clearCacheIfNecessary

  updateRemoteDataFiles

  rm -rf "$HTML_OUTPUT" && mkdir -p "$HTML_OUTPUT"
  # Set these up so rsync will not complain about either being missing
  mkdir -p "$HTML_OUTPUT/commit-snapshots"
  mkdir -p "$HTML_OUTPUT/review-drafts"

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
        rm -rf "$HTML_CACHE"
        exit 0
        ;;
      help)
        echo "Commands:"
        echo "  $0        Build the HTML Standard."
        echo "  $0 clean  Remove downloaded dependencies and generated files (then stop)."
        echo "  $0 help   Show this usage statement."
        echo
        echo "Build options:"
        echo "  -d|--docker     Use Docker to build in and serve from a container."
        echo "  -n|--no-update  Don't update before building; just build."
        echo "  -q|--quiet      Don't emit any messages except errors/warnings."
        echo "  -v|--verbose    Show verbose output from every build step."
        exit 0
        ;;
      -n|--no-update|--no-updates)
        DO_UPDATE=false
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
  GIT_FETCH_ARGS+=( "$ORIGIN_URL" master)
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
    echo "  git pull --rebase origin master"
    echo
    echo "This check can be bypassed with the --no-update option."
    exit 1
  fi
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

  while [[ "${target#$commonPart}" == "${target}" ]]; do
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
  local forwardPart="${target#$commonPart}"

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
  if [[ $HTML_SOURCE != $(pwd)/* ]]; then
    echo "When using Docker, the HTML source must be checked out in a subdirectory of the html-build repo. Cannot continue."
    exit 1
  fi

  # $SOURCE_RELATIVE helps on Windows with Git Bash, where /c/... is a symlink, which Docker doesn't like.
  SOURCE_RELATIVE=$(relativePath "$(pwd)" "$HTML_SOURCE")

  VERBOSE_OR_QUIET_FLAG=""
  $QUIET && VERBOSE_OR_QUIET_FLAG+="--quiet"
  $VERBOSE && VERBOSE_OR_QUIET_FLAG+="--verbose"

  NO_UPDATE_FLAG="--no-update"
  $DO_UPDATE && NO_UPDATE_FLAG=""

  DOCKER_ARGS=( --tag whatwg-html \
                --build-arg "html_source_dir=$SOURCE_RELATIVE" \
                --build-arg "verbose_or_quiet_flag=$VERBOSE_OR_QUIET_FLAG" \
                --build-arg "no_update_flag=$NO_UPDATE_FLAG" \
                --build-arg "sha_override=$HTML_SHA" )
  if $QUIET; then
    DOCKER_ARGS+=( --quiet )
  fi

  docker build "${DOCKER_ARGS[@]}" .
  echo "Running server on http://localhost:8080"
  docker run --rm -it -p 8080:80 whatwg-html
}

# Clears the $HTML_CACHE directory if the build tools have been updated since last run.
# Arguments: none
# Output:
# - $HTML_CACHE will be usable (possibly empty)
function clearCacheIfNecessary {
  if [[ -d "$HTML_CACHE" ]]; then
    PREV_BUILD_SHA=$( cat "$HTML_CACHE/last-build-sha.txt" 2>/dev/null || echo )
    CURRENT_BUILD_SHA=$( git rev-parse HEAD )

    if [[ $PREV_BUILD_SHA != "$CURRENT_BUILD_SHA" ]]; then
      $QUIET || echo "Build tools have been updated since last run; clearing the cache..."
      DO_UPDATE=true
      rm -rf "$HTML_CACHE"
      mkdir -p "$HTML_CACHE"
      echo "$CURRENT_BUILD_SHA" > "$HTML_CACHE/last-build-sha.txt"
    fi
  else
    mkdir -p "$HTML_CACHE"
  fi
}

# Updates the caniuse.json and mdn-spec-links-html.json files, if either
# $DO_UPDATE is true or they are not yet cached.
# Arguments: none
# Output:
# - $HTML_CACHE will contain a usable caniuse.json file
function updateRemoteDataFiles {
  CURL_ARGS=( --retry 2 )
  if ! $VERBOSE; then
    CURL_ARGS+=( --silent )
  fi

  CURL_CANIUSE_ARGS=( "${CURL_ARGS[@]}" \
    --output "$HTML_CACHE/caniuse.json" -k )
  CURL_MDN_SPEC_LINKS_ARGS=( "${CURL_ARGS[@]}" \
    --output "$HTML_CACHE/mdn-spec-links-html.json" -k )


  if [[ $DO_UPDATE == "true" || ! -f "$HTML_CACHE/caniuse.json" ]]; then
    rm -f "$HTML_CACHE/caniuse.json"
    $QUIET || echo "Downloading caniuse data..."
    curl "${CURL_CANIUSE_ARGS[@]}" \
      https://raw.githubusercontent.com/Fyrd/caniuse/master/data.json
  fi

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
  rm -rf "$HTML_TEMP" && mkdir -p "$HTML_TEMP"

  $QUIET || echo "Pre-processing the source..."
  SOURCE_LOCATION="$1"
  BUILD_TYPE="$2"
  cp -p  entities/out/entities.inc "$HTML_CACHE"
  cp -p  entities/out/entities-dtd.url "$HTML_CACHE"
  cp -p  quotes/out/cldr.inc "$HTML_CACHE"
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
    generateBacklinks "html" "$HTML_OUTPUT";

    # Singlepage Commit Snapshot
    COMMIT_DIR="$HTML_OUTPUT/commit-snapshots/$HTML_SHA"
    mkdir -p "$COMMIT_DIR"
    generateBacklinks  "snap" "$COMMIT_DIR";

    cp -p  entities/out/entities.json "$HTML_OUTPUT"
    cp -p "$HTML_TEMP/wattsi-output/xrefs.json" "$HTML_OUTPUT"

    # Multipage HTML and Dev Edition
    rm -rf "$HTML_OUTPUT/multipage"
    mv "$HTML_TEMP/wattsi-output/multipage-html" "$HTML_OUTPUT/multipage"
    mv "$HTML_TEMP/wattsi-output/multipage-dev" "$HTML_OUTPUT/dev"
    rm -rf "$HTML_TEMP"

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
    cp -pR "$HTML_SOURCE/dev" "$HTML_OUTPUT"
  else
    # Singlepage Review Draft
    YEARMONTH=$(basename "$SOURCE_LOCATION" .wattsi)
    NEWDIR="$HTML_OUTPUT/review-drafts/$YEARMONTH"
    mkdir -p "$NEWDIR"
    generateBacklinks "review" "$NEWDIR";
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

  rm -rf "$2"
  mkdir "$2"

  WATTSI_ARGS=()
  if $QUIET; then
    WATTSI_ARGS+=( --quiet )
  fi
  WATTSI_ARGS+=( "$1" "$HTML_SHA" "$2" "$BUILD_TYPE" \
    "$HTML_CACHE/caniuse.json" \
    "$HTML_CACHE/mdn-spec-links-html.json" \
    "$HIGHLIGHT_SERVER_URL" )
  if hash wattsi 2>/dev/null; then
    if [[ "$(wattsi --version | cut -d' ' -f2)" -lt "$WATTSI_LATEST" ]]; then
      echo
      echo "Warning: Your wattsi version is out of date. You should to rebuild an"
      echo "up-to-date wattsi binary from the wattsi sources."
      echo
    fi
    WATTSI_RESULT="0"
    wattsi "${WATTSI_ARGS[@]}" || WATTSI_RESULT=$?
  else
    LOCAL_WATTSI=false
    $QUIET || echo
    $QUIET || echo "Local wattsi is not present; trying the build server..."

    CURL_ARGS=( https://build.whatwg.org/wattsi \
                --form "source=@$1" \
                --form "sha=$HTML_SHA" \
                --form "build=$BUILD_TYPE" \
                --form "caniuse=@$HTML_CACHE/caniuse.json" \
                --form "mdn=@$HTML_CACHE/mdn-spec-links-html.json" \
                --dump-header "$HTML_TEMP/wattsi-headers.txt" \
                --output "$HTML_TEMP/wattsi-output.zip" )
    if $VERBOSE; then
      CURL_ARGS+=( --verbose )
    elif $QUIET; then
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

# Runs backlink generation post-processing on the output of Wattsi
# Arguments:
# - $1: the spec variant (e.g. "snap" or "html") to run on
# - $2: The destination directory for the output file
# Output:
# - $2 will contain an index.html file derived from the given variant, with post-processing applied
function generateBacklinks {
  perl .post-process-partial-backlink-generator.pl "$HTML_TEMP/wattsi-output/index-$1" > "$2/index.html";
}

# Starts the syntax-highlighting Python server
# Arguments: none
# Output:
# - A server will be running in the background, at $HIGHLIGHT_SERVER_URL
# - $HIGHLIGHT_SERVER_PID will be set for later use by stopHighlightServer
function startHighlightServer {
  HIGHLIGHT_SERVER_ARGS=()
  $QUIET && HIGHLIGHT_SERVER_ARGS+=( --quiet )
  # shellcheck disable=SC2068
  bs-highlighter-server ${HIGHLIGHT_SERVER_ARGS[@]+"${HIGHLIGHT_SERVER_ARGS[@]}"} &
  HIGHLIGHT_SERVER_PID=$!

  trap stopHighlightServer EXIT
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

main "$@"
