#!/bin/bash
set -e
HTML_GIT_CLONE_OPTIONS=${HTML_GIT_CLONE_OPTIONS:-"--depth 1"}

# cd to the directory containing this script
cd "$( dirname "${BASH_SOURCE[0]}" )"
DIR=$(pwd)

DO_UPDATE=true
USE_DOCKER=false
VERBOSE=false
QUIET=false
export DO_UPDATE
export VERBOSE
export QUIET

HTML_CACHE=${HTML_CACHE:-$DIR/.cache}
export HTML_CACHE

HTML_TEMP=${HTML_TEMP:-$DIR/.temp}
export HTML_TEMP

HTML_OUTPUT=${HTML_OUTPUT:-$DIR/output}
export HTML_OUTPUT

for arg in "$@"
do
  case $arg in
    -c|--clean)
      rm -rf "$HTML_CACHE"
      exit 0
      ;;
    -h|--help)
      echo "Usage: $0 [-c|--clean]"
      echo "       $0 [-h|--help]"
      echo "       $0 [-d|--docker]"
      echo "       $0 [-n|--no-update] [-q|--quiet] [-v|--verbose]"
      echo
      echo "  -c|--clean      Remove downloaded dependencies and generated files (then stop)."
      echo "  -h|--help       Show this usage statement."
      echo "  -n|--no-update  Don't update before building; just build."
      echo "  -d|--docker     Use Docker to build in and serve from a container."
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

# $SKIP_BUILD_UPDATE_CHECK is set inside the Dockerfile so that we don't check for updates both inside and outside
# the Docker container.
if [[ "$DO_UPDATE" == true && "$SKIP_BUILD_UPDATE_CHECK" != true ]]; then
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
  if [ "$NEW_COMMITS" != "0" ]; then
    $QUIET || echo
    echo -n "Your local branch is $NEW_COMMITS "
    [ "$NEW_COMMITS" == "1" ] && echo -n commit || echo -n commits
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
fi

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
if [ "1" = "$choice" ]; then
  read -r -e -p "Path to your existing clone: "
  HTML_SOURCE=$(echo "$REPLY" | xargs) # trims leading/trailing space
  if [[ "$HTML_SOURCE" = "" ]]; then
    chooseRepo
  fi
  confirmRepo
elif [ "2" = "$choice" ]; then
  HTML_REPO=https://github.com/whatwg/html.git
  confirmRepo
elif [ "3" = "$choice" ]; then
  echo
  read -r -e -p "GitHub username of fork owner: "
  GH_USERNAME=$(echo "$REPLY" | xargs) # trims leading/trailing space
  if [ -z "$GH_USERNAME" ]; then
    chooseRepo
  fi
  echo
  echo "Does a fork already exist at https://github.com/$GH_USERNAME/html?"
  echo
  read -r -e -p "Y or N? " yn
  if [[ "y" = "$yn" || "Y" = "$yn" ]]; then
    HTML_REPO="https://github.com/$GH_USERNAME/html.git"
    confirmRepo
  else
    echo
    echo "Before proceeding, first go to https://github.com/whatwg/html and create a fork."
    exit
  fi
elif [ "4" = "$choice" ]; then
  echo
  read -r -e -p "URL: "
  REPLY=$(echo "$REPLY" | xargs) # trims leading/trailing space
  if [ -z "$REPLY" ]; then
    chooseRepo
  fi
  HTML_REPO=$REPLY
  confirmRepo
elif [[ "5" = "$choice" || "q" = "$choice" || "Q" = "$choice" ]]; then
  echo
  echo "Can't build without a source repo to build from. Quitting..."
  exit
else
  chooseRepo
fi
}

function confirmRepo {
  if [ -n "$HTML_SOURCE" ]; then
    if [ -f "$HTML_SOURCE/source" ]; then
      echo
      echo "OK, build from the $HTML_SOURCE/source file?"
      echo
      read -r -e -p "Y or N? " yn
      if [[ "y" = "$yn" || "Y" = "$yn" ]]; then
        return
      else
        unset HTML_SOURCE
        chooseRepo
      fi
    else
      echo
      echo "$HTML_SOURCE/source file doesn't exist. Please choose another option."
      unset HTML_SOURCE
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
  if [[ "y" = "$yn" || "Y" = "$yn" ]]; then
    git clone "${GIT_CLONE_ARGS[@]}"
  else
    unset HTML_SOURCE
    chooseRepo
  fi
}

$QUIET || echo "Looking for the HTML source (set HTML_SOURCE to override)..."
if [ -z "$HTML_SOURCE" ]; then
  PARENT_DIR=$(dirname "$DIR")
  if [ -f "$PARENT_DIR/html/source" ]; then
    HTML_SOURCE=$PARENT_DIR/html
    $QUIET || echo "Found $HTML_SOURCE (alongside html-build)..."
  else
    if [ -f "$DIR/html/source" ]; then
      HTML_SOURCE=$DIR/html
      $QUIET || echo "Found $HTML_SOURCE (inside html-build)..."
    else
      $QUIET || echo "Didn't find the HTML source on your system..."
      chooseRepo
    fi
  fi
else
  if [ -f "$HTML_SOURCE/source" ]; then
    $QUIET || echo "Found $HTML_SOURCE (from HTML_SOURCE)..."
  else
    $QUIET || echo "Looked in the $HTML_SOURCE directory but didn't find HTML source there..."
    unset HTML_SOURCE
    chooseRepo
  fi
fi
export HTML_SOURCE

# From http://stackoverflow.com/a/12498485
function relativePath {
  # both $1 and $2 are absolute paths beginning with /
  # returns relative path to $2 from $1
  local source=$1
  local target=$2

  local commonPart=$source
  local result=""

  while [[ "${target#$commonPart}" == "${target}" ]]; do
    # no match, means that candidate common part is not correct
    # go up one level (reduce common part)
    commonPart=$(dirname "$commonPart")
    # and record that we went back, with correct / handling
    if [[ -z $result ]]; then
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
  if [[ -n $result ]] && [[ -n $forwardPart ]]; then
    result="$result$forwardPart"
  elif [[ -n $forwardPart ]]; then
    # extra slash removal
    result="${forwardPart:1}"
  fi

  echo "$result"
}

if [ "$USE_DOCKER" == true ]; then
  if [[ "$HTML_SOURCE" != $(pwd)/* ]]; then
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
                --build-arg "no_update_flag=$NO_UPDATE_FLAG" )
  if $QUIET; then
    DOCKER_ARGS+=( --quiet )
  fi

  docker build "${DOCKER_ARGS[@]}" .
  docker run --rm -it -p 8080:80 whatwg-html
  exit 0
fi


$QUIET || echo "Linting the source file..."
./lint.sh "$HTML_SOURCE/source" || {
  echo
  echo "There were lint errors. Stopping."
  exit 1
}

rm -rf "$HTML_TEMP" && mkdir -p "$HTML_TEMP"
rm -rf "$HTML_OUTPUT" && mkdir -p "$HTML_OUTPUT"

if [ -d "$HTML_CACHE" ]; then
  PREV_BUILD_SHA=$( cat "$HTML_CACHE/last-build-sha.txt" 2>/dev/null || echo )
  CURRENT_BUILD_SHA=$( git rev-parse HEAD )

  if [ "$PREV_BUILD_SHA" != "$CURRENT_BUILD_SHA" ]; then
    $QUIET || echo "Build tools have been updated since last run; clearing the cache..."
    DO_UPDATE=true
    rm -rf "$HTML_CACHE"
    mkdir -p "$HTML_CACHE"
    echo "$CURRENT_BUILD_SHA" > "$HTML_CACHE/last-build-sha.txt"
  fi
else
  mkdir -p "$HTML_CACHE"
fi

CURL_ARGS=()
if ! $VERBOSE; then
  CURL_ARGS+=( --silent )
fi

CURL_CANIUSE_ARGS=( ${CURL_ARGS[@]} --output "$HTML_CACHE/caniuse.json" -k )
CURL_W3CBUGS_ARGS=( ${CURL_ARGS[@]} --output "$HTML_CACHE/w3cbugs.csv" )

if [ "$DO_UPDATE" == true ] || [ ! -f "$HTML_CACHE/caniuse.json" ]; then
  rm -f "$HTML_CACHE/caniuse.json"
  $QUIET || echo "Downloading caniuse data..."
  curl "${CURL_CANIUSE_ARGS[@]}" \
    https://raw.githubusercontent.com/Fyrd/caniuse/master/data.json
fi

if [ "$DO_UPDATE" == true ] || [ ! -f "$HTML_CACHE/w3cbugs.csv" ]; then
  rm -f "$HTML_CACHE/w3cbugs.csv"
  $QUIET || echo "Downloading list of W3C bugzilla bugs..."
  curl "${CURL_W3CBUGS_ARGS[@]}" \
    'https://www.w3.org/Bugs/Public/buglist.cgi?columnlist=bug_file_loc,short_desc&query_format=advanced&resolution=---&ctype=csv&status_whiteboard=whatwg-resolved&status_whiteboard_type=notregexp&bug_file_loc=http&bug_file_loc_type=substring&product=WHATWG&product=HTML%20WG&product=CSS&product=WebAppsWG'
fi

$QUIET || echo "Pre-processing the source..."
cp -p  entities/out/entities.inc "$HTML_CACHE"
cp -p  entities/out/entities-dtd.url "$HTML_CACHE"
cp -p  quotes/out/cldr.inc "$HTML_CACHE"
if $VERBOSE; then
  perl .pre-process-main.pl --verbose < "$HTML_SOURCE/source" > "$HTML_TEMP/source-expanded-1"
else
  perl .pre-process-main.pl < "$HTML_SOURCE/source" > "$HTML_TEMP/source-expanded-1"
fi
perl .pre-process-annotate-attributes.pl < "$HTML_TEMP/source-expanded-1" > "$HTML_TEMP/source-expanded-2" # this one could be merged
perl .pre-process-tag-omission.pl < "$HTML_TEMP/source-expanded-2" | perl .pre-process-index-generator.pl > "$HTML_TEMP/source-whatwg-complete" # this one could be merged

function runWattsi {
  # Input arguments: $1 is the file to run wattsi on, $2 is a directory for wattsi to write output to
  # Output:
  # - Sets global variable $WATTSI_RESULT to an exit code (or equivalent, for HTTP version)
  # - $HTML_TEMP/wattsi-output directory will contain the output from wattsi on success
  # - $HTML_TEMP/wattsi-output.txt will contain the output from wattsi, on both success and failure

  rm -rf "$2"
  mkdir "$2"

  WATTSI_ARGS=()
  if $QUIET; then
    WATTSI_ARGS+=( --quiet )
  fi
  WATTSI_ARGS+=( "$1" "$2" "$HTML_CACHE/caniuse.json" "$HTML_CACHE/w3cbugs.csv" )
  if hash wattsi 2>/dev/null; then
    WATTSI_RESULT=$(wattsi "${WATTSI_ARGS[@]}" \
      > "$HTML_TEMP/wattsi-output.txt"; echo $?)
  else
    $QUIET || echo
    $QUIET || echo "Local wattsi is not present; trying the build server..."

    CURL_ARGS=( https://build.whatwg.org/wattsi \
                --form "source=@$1" \
                --form "caniuse=@$HTML_CACHE/caniuse.json" \
                --form "w3cbugs=@$HTML_CACHE/w3cbugs.csv" \
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
      if [ "$NAME" == "Wattsi-Exit-Code" ]; then
        WATTSI_RESULT=$(echo "$VALUE" | tr -d ' \r\n')
        break
      fi
    done < "$HTML_TEMP/wattsi-headers.txt"

    if [ "$WATTSI_RESULT" != "0" ]; then
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

runWattsi "$HTML_TEMP/source-whatwg-complete" "$HTML_TEMP/wattsi-output"
if [ "$WATTSI_RESULT" == "0" ]; then
    "$QUIET" || grep -v '^$' "$HTML_TEMP/wattsi-output.txt" # trim blank lines
else
  grep -v '^$' "$HTML_TEMP/wattsi-output.txt" # trim blank lines
  if [ "$WATTSI_RESULT" == "65" ]; then
    echo
    echo "There were errors. Running again to show the original line numbers."
    echo
    runWattsi "$HTML_SOURCE/source" "$HTML_TEMP/wattsi-raw-source-output"
    grep -v '^$' "$HTML_TEMP/wattsi-output.txt" # trim blank lines
  fi
  echo
  echo "There were errors. Stopping."
  exit "$WATTSI_RESULT"
fi

perl .post-process-partial-backlink-generator.pl "$HTML_TEMP/wattsi-output/index-html" > "$HTML_OUTPUT/index.html";
cp -p  "$HTML_TEMP/wattsi-output/xrefs.json" "$HTML_OUTPUT"
cp -p  entities/out/entities.json "$HTML_OUTPUT"

# multipage setup
rm -rf "$HTML_OUTPUT/multipage"
mv "$HTML_TEMP/wattsi-output/multipage-html" "$HTML_OUTPUT/multipage"
rm -rf "$HTML_TEMP"

cp -p  "$HTML_SOURCE/.htaccess" "$HTML_OUTPUT"
cp -p  "$HTML_SOURCE/404.html" "$HTML_OUTPUT"
cp -pR "$HTML_SOURCE/fonts" "$HTML_OUTPUT"
cp -pR "$HTML_SOURCE/images" "$HTML_OUTPUT"
cp -pR "$HTML_SOURCE/demos" "$HTML_OUTPUT"
cp -pR "$HTML_SOURCE/link-fixup.js" "$HTML_OUTPUT"

$QUIET || echo
$QUIET || echo "Success!"
