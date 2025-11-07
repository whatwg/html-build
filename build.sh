#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# cd to the directory containing this script
cd "$(dirname "$0")"
DIR=$(pwd)

# The latest required version of Bikeshed. Update this if the build depends on
# new features or bugfixes in Bikeshed.
BIKESHED_LATEST="5.4.0"

# The latest required version of Wattsi. Update this if you change how ./build.sh invokes Wattsi;
# it will cause a warning if Wattsi's self-reported version is lower. Note that there's no need to
# update this on every revision of Wattsi; only do so when a warning is justified.
declare -r WATTSI_LATEST=140

# Shared state variables throughout this script
LOCAL_WATTSI=true
WATTSI_RESULT=0
USE_BIKESHED=false
DO_UPDATE=true
DO_LINT=true
DO_HIGHLIGHT=true
SINGLE_PAGE_ONLY=false
USE_DOCKER=false
USE_SERVER=false
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

# This is used by child scripts, and so we export it
export HTML_CACHE

# Used specifically when the Dockerfile calls this script
SKIP_BUILD_UPDATE_CHECK=${SKIP_BUILD_UPDATE_CHECK:-false}
SHA_OVERRIDE=${SHA_OVERRIDE:-}
BUILD_SHA_OVERRIDE=${BUILD_SHA_OVERRIDE:-}

# This needs to be coordinated with the bs-highlighter package
declare -r HIGHLIGHT_SERVER_URL="http://127.0.0.1:8080"

declare -r SERVE_PORT=8080

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

  local html_git_dir="$HTML_SOURCE/.git/"
  HTML_SHA=${SHA_OVERRIDE:-$(git --git-dir="$html_git_dir" rev-parse HEAD)}

  if [[ $USE_DOCKER == "true" ]]; then
    doDockerBuild
    exit 0
  fi

  if [[ $USE_SERVER == "true" ]]; then
    doServerBuild

    if [[ $SERVE == "true" ]]; then
      cd "$HTML_OUTPUT"
      python3 -m http.server "$SERVE_PORT"
    fi

    exit 0
  fi

  if [[ $USE_BIKESHED == "true" ]]; then
    checkBikeshed
  else
    checkWattsi
    ensureHighlighterInstalled

    doLint

    updateRemoteDataFiles

    startHighlightServer
  fi

  processSource "source" "default"

  if [[ -e "$html_git_dir" ]]; then
    # This is based on https://github.com/whatwg/whatwg.org/pull/201 and should be kept synchronized
    # with that.
    local changed_files
    changed_files=$(git --git-dir="$html_git_dir" show --format="format:" --name-only HEAD)

    local changed
    for changed in $changed_files; do # Omit quotes around variable to split on whitespace
      if ! [[ "$changed" =~ ^review-drafts/.*.wattsi$ ]]; then
        continue
      fi
      processSource "$changed" "review"
    done
  else
    echo ""
    echo "Skipping review draft production as the .git directory is not present"
    echo "(This always happens if you use the --docker or --remote options.)"
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
  local arg
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
        echo "  -b|--bikeshed     Use Bikeshed instead of Wattsi. (experimental)"
        echo "  -d|--docker       Use Docker to build in a container."
        echo "  -r|--remote       Use the build server."
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
      -b|--bikeshed)
        USE_BIKESHED=true
        SINGLE_PAGE_ONLY=true
        ;;
      -d|--docker)
        USE_DOCKER=true
        ;;
      -r|--remote)
        USE_SERVER=true
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

  if [[ $USE_DOCKER == "true" && $USE_SERVER == "true" ]]; then
    echo "Error: --docker and --remote are mutually exclusive."
    exit 1
  fi
}

# Checks if the html-build repository is up to date
# Arguments: none
# Output: will tell the user and exit the script with code 1 if not up to date
function checkHTMLBuildIsUpToDate {
  $QUIET || echo "Checking if html-build is up to date..."

  # TODO: `git remote get-url origin` is nicer, but new in Git 2.7.
  local origin_url
  origin_url=$(git config --get remote.origin.url)

  local git_fetch_args=()
  if ! $VERBOSE ; then
    git_fetch_args+=( --quiet )
  fi
  git_fetch_args+=( "$origin_url" main)
  git fetch "${git_fetch_args[@]}"

  local new_commits
  new_commits=$(git rev-list --count HEAD..FETCH_HEAD)
  if [[ $new_commits != "0" ]]; then
    $QUIET || echo
    echo -n "Your local branch is $new_commits "
    [[ $new_commits == "1" ]] && echo -n "commit" || echo -n "commits"
    echo " behind $origin_url:"
    git --no-pager log --oneline HEAD..FETCH_HEAD
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
    local parent_dir
    parent_dir=$(dirname "$DIR")

    if [[ -f "$parent_dir/html/source" ]]; then
      HTML_SOURCE="$parent_dir/html"
      $QUIET || echo "Found $HTML_SOURCE (alongside html-build)..."
    else
      if [[ -f "$DIR/html/source" ]]; then
        HTML_SOURCE="$DIR/html"
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

  local choice
  read -r -e -p "Choose 1-5: " choice
  if [[ $choice == "1" ]]; then
    read -r -e -p "Path to your existing clone: "
    HTML_SOURCE=$(echo "$REPLY" | xargs) # trims leading/trailing space
    if [[ $HTML_SOURCE = "" ]]; then
      chooseRepo
    fi
    confirmRepo
  elif [[ $choice == "2" ]]; then
    HTML_REPO="https://github.com/whatwg/html.git"
    confirmRepo
  elif [[ $choice == "3" ]]; then
    echo

    local gh_username
    read -r -e -p "GitHub username of fork owner: " gh_username
    gh_username=$(echo "$gh_username" | xargs) # trims leading/trailing space
    if [[ $gh_username == "" ]]; then
      chooseRepo
    fi
    echo
    echo "Does a fork already exist at https://github.com/$gh_username/html?"
    echo
    read -r -e -p "Y or N? " yn
    if [[ $yn == "y" || $yn == "Y" ]]; then
      HTML_REPO="https://github.com/$gh_username/html.git"
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

      local build_yn
      read -r -e -p "Y or N? " build_yn
      if [[ $build_yn == "y" || $build_yn == "Y" ]]; then
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

  local clone_yn
  read -r -e -p "Y or N? " clone_yn

  local git_clone_args=( "$HTML_GIT_CLONE_OPTIONS" )
  $QUIET && git_clone_args+=( --quiet )
  $VERBOSE && git_clone_args+=( --verbose )
  git_clone_args+=( "$HTML_REPO" "$HTML_SOURCE" )
  if [[ $clone_yn == "y" || $clone_yn == "Y" ]]; then
    git clone "${git_clone_args[@]}"
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
  local docker_pull_args=()
  $QUIET && docker_pull_args+=( --quiet )
  docker_pull_args+=( ghcr.io/whatwg/wattsi:latest )
  docker pull "${docker_pull_args[@]}"

  local docker_build_args=( --tag whatwg-html )
  $QUIET && docker_build_args+=( --quiet )
  docker build "${docker_build_args[@]}" .

  local docker_run_args=()
  $SERVE && docker_run_args+=( --publish "$SERVE_PORT:$SERVE_PORT" )
  docker_run_args+=( whatwg-html )
  $QUIET && docker_run_args+=( --quiet )
  $VERBOSE && docker_run_args+=( --verbose )
  $DO_UPDATE || docker_run_args+=( --no-update )
  $DO_LINT || docker_run_args+=( --no-lint )
  $DO_HIGHLIGHT || docker_run_args+=( --no-highlight )
  $SINGLE_PAGE_ONLY && docker_run_args+=( --single-page )
  $SERVE && docker_run_args+=( --serve )

  # Pass in the html-build SHA (since there's no .git directory inside the container)
  docker run --rm --interactive --tty \
             --env "BUILD_SHA_OVERRIDE=$(git rev-parse HEAD)" \
             --mount "type=bind,source=$HTML_SOURCE,destination=/whatwg/html-build/html,readonly=1" \
             --mount "type=bind,source=$HTML_CACHE,destination=/whatwg/html-build/.cache" \
             --mount "type=bind,source=$HTML_OUTPUT,destination=/whatwg/html-build/output" \
             "${docker_run_args[@]}"
}

# Performs the build using the build server, zipping up the input, sending it to the server, and
# unzipping the output.
# Output: the $HTML_OUTPUT directory will contain the built files
function doServerBuild {
  clearDir "$HTML_TEMP"

  local input_zip="build-server-input.zip"
  local build_server_output="build-server-output"
  local build_server_headers="build-server-headers.txt"

  # Keep include list in sync with `processSource`
  #
  # We use an allowlist (--include) instead of a blocklist (--exclude) to avoid accidentally
  # sending files that the user might not anticipate sending to a remote server, e.g. their
  # private-notes-on-current-pull-request.txt.
  #
  # The contents of fonts/, images/, and dev/ are not round-tripped to the server, but instead
  # copied below in this function. (We still send the directories to avoid the build script on the
  # server getting confused about their absence.) demos/ needs to be sent in full for inlining.
  local zip_args=(
    --recurse-paths "$HTML_TEMP/$input_zip" . \
    --include ./source ./404.html "./*.js" ./styles.css \
              ./fonts/ ./images/ ./dev/ "./demos/*"
  )
  $QUIET && zip_args+=( --quiet )
  (cd "$HTML_SOURCE" && zip "${zip_args[@]}")

  local query_params=()
  $QUIET && query_params+=( quiet )
  $VERBOSE && query_params+=( verbose )
  $DO_UPDATE || query_params+=( no-update )
  $DO_LINT || query_params+=( no-lint )
  $DO_HIGHLIGHT || query_params+=( no-highlight )
  $SINGLE_PAGE_ONLY && query_params+=( single-page )

  $QUIET || echo
  $QUIET || echo "Sending files to the build server..."

  local query_string
  query_string=$(joinBy "\&" "${query_params[@]-''}")
  local curl_url="https://build.whatwg.org/html-build?${query_string}"
  local curl_args=( "$curl_url" \
                    --form "html=@$HTML_TEMP/$input_zip" \
                    --form "sha=$HTML_SHA" \
                    --dump-header "$HTML_TEMP/$build_server_headers" \
                    --output "$HTML_TEMP/$build_server_output" )
  $QUIET && curl_args+=( --silent )
  $VERBOSE && curl_args+=( --verbose )
  curl "${curl_args[@]}"

  # Read exit code from the Exit-Code header and assume failure if not found
  local build_server_result=1
  local name value
  while IFS=":" read -r name value; do
    shopt -s nocasematch
    if [[ $name == "Exit-Code" ]]; then
      build_server_result=$(echo "$value" | tr -d ' \r\n')
      break
    fi
    shopt -u nocasematch
  done < "$HTML_TEMP/$build_server_headers"

  if [[ $build_server_result != "0" ]]; then
    cat "$HTML_TEMP/$build_server_output"
    exit "$build_server_result"
  else
    local unzip_args=()
    # Note: Don't use the -v flag; it doesn't work in combination with -d
    if [[ "$VERBOSE" == "false" ]]; then
      unzip_args+=( -qq )
    fi
    unzip_args+=( "$HTML_TEMP/$build_server_output" -d "$HTML_OUTPUT" )
    unzip "${unzip_args[@]}"
    cp -pR "$HTML_SOURCE/fonts" "$HTML_OUTPUT"
    cp -pR "$HTML_SOURCE/images" "$HTML_OUTPUT"

    if [[ "$SINGLE_PAGE_ONLY" == "false" ]]; then
      cp -pR "$HTML_SOURCE/dev" "$HTML_OUTPUT"
    fi

    $QUIET || echo
    $QUIET || echo "Build server output:"
    cat "$HTML_OUTPUT/output.txt"
    rm "$HTML_OUTPUT/output.txt"
  fi
}

# Clears the $HTML_CACHE directory if the build tools have been updated since last run.
# Arguments: none
# Output:
# - $HTML_CACHE will be usable (possibly empty)
function clearCacheIfNecessary {
  if [[ -d "$HTML_CACHE" ]]; then
    local prev_build_sha
    prev_build_sha=$( cat "$HTML_CACHE/last-build-sha.txt" 2>/dev/null || echo )

    local current_build_sha
    current_build_sha=${BUILD_SHA_OVERRIDE:-$(git rev-parse HEAD)}

    if [[ "$prev_build_sha" != "$current_build_sha" ]]; then
      $QUIET || echo "Build tools have been updated since last run; clearing the cache..."
      DO_UPDATE=true
      clearDir "$HTML_CACHE"
      echo "$current_build_sha" > "$HTML_CACHE/last-build-sha.txt"
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
  if [[ $DO_UPDATE == "true" || ! -f "$HTML_CACHE/mdn-spec-links-html.json" ]]; then
    rm -f "$HTML_CACHE/mdn-spec-links-html.json"
    $QUIET || echo "Downloading mdn-spec-links/html.json..."

    local curl_args=( "https://raw.githubusercontent.com/w3c/mdn-spec-links/master/html.json" \
                      --output "$HTML_CACHE/mdn-spec-links-html.json" \
                      --retry 2 )
    if ! $VERBOSE; then
      curl_args+=( --silent )
    fi
    curl "${curl_args[@]}"
  fi
}

# Performs a build of the HTML source file into the resulting output
# - Arguments:
#   - $1: the filename of the source file within HTML_SOURCE (e.g. "source")
#   - $2: the build type, either "default" or "review"
# - Output:
#   - $HTML_OUTPUT will contain the built files
function processSource {
  local source_location="$1"
  local build_type="$2"

  clearDir "$HTML_TEMP"

  $QUIET || echo "Pre-processing the source..."
  cp -p  entities/out/entities.inc "$HTML_CACHE"
  cp -p  entities/out/entities-dtd.url "$HTML_CACHE"
  runRustTools <"$HTML_SOURCE/$source_location" >"$HTML_TEMP/source-whatwg-complete"

  if [[ $USE_BIKESHED == "true" ]]; then
    clearDir "$HTML_TEMP/bikeshed-output"

    node wattsi2bikeshed.js "$HTML_TEMP/source-whatwg-complete" "$HTML_TEMP/source-whatwg-complete.bs"

    local bikeshed_args=( --force )
    $DO_UPDATE || bikeshed_args+=( --no-update )
    bikeshed "${bikeshed_args[@]}" spec "$HTML_TEMP/source-whatwg-complete.bs" "$HTML_TEMP/bikeshed-output/index.html" --md-Text-Macro="SHA $HTML_SHA" --md-Text-Macro="COMMIT-SHA $HTML_SHA"
  else
    runWattsi "$HTML_TEMP/source-whatwg-complete" "$HTML_TEMP/wattsi-output"
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
        runWattsi "$HTML_SOURCE/$source_location" "$HTML_TEMP/wattsi-raw-source-output"
        if [[ $LOCAL_WATTSI != "true" ]]; then
          grep -v '^$' "$HTML_TEMP/wattsi-output.txt" # trim blank lines
        fi
      fi
      echo
      echo "There were errors. Stopping."
      exit "$WATTSI_RESULT"
    fi
  fi

  # Keep the list of files copied from $HTML_SOURCE in sync with `doServerBuild`

  if [[ $build_type == "default" ]]; then
    # Singlepage HTML
    if [[ $USE_BIKESHED == "true" ]]; then
      mv "$HTML_TEMP/bikeshed-output/index.html" "$HTML_OUTPUT/index.html"
    else
      runRustTools --singlepage-post <"$HTML_TEMP/wattsi-output/index-html" >"$HTML_OUTPUT/index.html"
    fi

    if [[ $SINGLE_PAGE_ONLY == "false" ]]; then
      # Singlepage Commit Snapshot
      local commit_dir="$HTML_OUTPUT/commit-snapshots/$HTML_SHA"
      mkdir -p "$commit_dir"
      mv "$HTML_TEMP/wattsi-output/index-snap" "$commit_dir/index.html"

      # Multipage HTML and Dev Edition
      mv "$HTML_TEMP/wattsi-output/multipage-html" "$HTML_OUTPUT/multipage"
      mv "$HTML_TEMP/wattsi-output/multipage-dev" "$HTML_OUTPUT/dev"

      cp -pR "$HTML_SOURCE/dev" "$HTML_OUTPUT"
    fi

    cp -p  entities/out/entities.json "$HTML_OUTPUT"
    if [[ $USE_BIKESHED == "false" ]]; then
      cp -p "$HTML_TEMP/wattsi-output/xrefs.json" "$HTML_OUTPUT"
    fi

    clearDir "$HTML_TEMP"

    echo "User-agent: *
Disallow: /commit-snapshots/
Disallow: /review-drafts/" > "$HTML_OUTPUT/robots.txt"
    cp -p  "$HTML_SOURCE/404.html" "$HTML_OUTPUT"
    cp -p "$HTML_SOURCE/"*.js "$HTML_OUTPUT"
    cp -p "$HTML_SOURCE/styles.css" "$HTML_OUTPUT"
    cp -pR "$HTML_SOURCE/fonts" "$HTML_OUTPUT"
    cp -pR "$HTML_SOURCE/images" "$HTML_OUTPUT"
    cp -pR "$HTML_SOURCE/demos" "$HTML_OUTPUT"
  else
    # Singlepage Review Draft
    local year_month
    year_month=$(basename "$source_location" .wattsi)

    local new_dir="$HTML_OUTPUT/review-drafts/$year_month"
    mkdir -p "$new_dir"
    mv "$HTML_TEMP/wattsi-output/index-review" "$new_dir/index.html"
  fi
}

# Checks if Bikeshed is available and up to date
# - Arguments: none
# - Output:
#   - Will echo any errors and exit the script with error code 1 if the required
#     version is not available.
function checkBikeshed {
  if hash bikeshed 2>/dev/null; then
    BIKESHED_INSTALLED=$(bikeshed --version)
    if ! printf "%s\n%s" "$BIKESHED_LATEST" "$BIKESHED_INSTALLED" | sort -V -C; then
      echo "Error: bikeshed version $BIKESHED_LATEST or newer is required."
      exit 1
    fi
  else
    echo "Error: bikeshed is required."
    exit 1
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

# Runs the Rust-based build tools, either with the version in $PATH or by using cargo to compile
# them beforehand.
# - Arguments: all arguments to pass to the tools
# - Output: whatever the tools output
function runRustTools {
  if hash html-build 2>/dev/null; then
    html-build "$@"
  else
    local cargo_args=( --release )
    $VERBOSE && cargo_args+=( --verbose )
    $QUIET && cargo_args+=( --quiet )
    cargo_args+=( -- )
    cargo run "${cargo_args[@]}" "$@"
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
  local source_file="$1"
  local output_dir="$2"

  clearDir "$output_dir"

  if [[ "$LOCAL_WATTSI" == "true" ]]; then
    local wattsi_args=()
    $QUIET && wattsi_args+=( --quiet )
    $SINGLE_PAGE_ONLY && wattsi_args+=( --single-page-only )
    wattsi_args+=( "$source_file" "$HTML_SHA" "$output_dir" "$build_type" "$HTML_CACHE/mdn-spec-links-html.json" )
    if [[ "$DO_HIGHLIGHT" == "true" ]]; then
      wattsi_args+=( "$HIGHLIGHT_SERVER_URL" )
    fi

    WATTSI_RESULT="0"
    wattsi "${wattsi_args[@]}" || WATTSI_RESULT=$?
  else
    $QUIET || echo
    $QUIET || echo "Local wattsi not present; trying the build server..."


    local query_params=()
    $QUIET && query_params+=( quiet )
    $SINGLE_PAGE_ONLY && query_params+=( single-page-only )

    local query_string
    query_string=$(joinBy "\&" "${query_params[@]-''}")
    local curl_url="https://build.whatwg.org/wattsi?${query_string}"

    local curl_args=( "$curl_url" \
                      --form "source=@$source_file" \
                      --form "sha=$HTML_SHA" \
                      --form "build=$build_type" \
                      --form "mdn=@$HTML_CACHE/mdn-spec-links-html.json" \
                      --dump-header "$HTML_TEMP/wattsi-headers.txt" \
                      --output "$HTML_TEMP/wattsi-output.zip" )
    $QUIET && curl_args+=( --silent )
    $VERBOSE && curl_args+=( --verbose )
    curl "${curl_args[@]}"

    # read exit code from the Exit-Code header and assume failure if not found
    WATTSI_RESULT="1"
    local name value
    while IFS=":" read -r name value; do
      shopt -s nocasematch
      if [[ $name == "Exit-Code" ]]; then
        WATTSI_RESULT=$(echo "$value" | tr -d ' \r\n')
        break
      fi
      shopt -u nocasematch
    done < "$HTML_TEMP/wattsi-headers.txt"

    if [[ $WATTSI_RESULT != "0" ]]; then
      mv "$HTML_TEMP/wattsi-output.zip" "$HTML_TEMP/wattsi-output.txt"
    else
      local unzip_args=()
      # Note: Don't use the -v flag; it doesn't work in combination with -d
      if ! $VERBOSE; then
        unzip_args+=( -qq )
      fi
      unzip_args+=( "$HTML_TEMP/wattsi-output.zip" -d "$output_dir" )
      unzip "${unzip_args[@]}"
      mv "$output_dir/output.txt" "$HTML_TEMP/wattsi-output.txt"
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
    local highlight_server_args=()
    $QUIET && highlight_server_args+=( --quiet )
    bs-highlighter-server ${highlight_server_args[@]+"${highlight_server_args[@]}"} &
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

# Joins parameters $2 onward with the separator given in $1
# Arguments:
# - $1: the separator string
# - $2...: the strings to join
# Output: echoes the joined string
function joinBy {
  local d=${1-} f=${2-}
  if shift 2; then
    printf %s "$f" "${@/#/$d}"
  fi
}

main "$@"
