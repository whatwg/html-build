#!/bin/bash
set -e
HTML_GIT_CLONE_OPTIONS=${HTML_GIT_CLONE_OPTIONS:-"--depth 1"}

# cd to the directory containing this script
cd "$( dirname "${BASH_SOURCE[0]}" )"
DIR=$(pwd)

DO_UPDATE=true
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
      rm -rf $HTML_CACHE
      exit 0
      ;;
    -h|--help)
      echo "Usage: $0 [-c|--clean]"
      echo "       $0 [-h|--help]"
      echo "Usage: $0 [-n|--no-update] [-q|--quiet] [-v|--verbose]"
      echo
      echo "  -c|--clean      Remove downloaded dependencies and generated files (then stop)."
      echo "  -h|--help       Show this usage statement."
      echo "  -n|--no-update  Don't update before building; just build."
      echo "  -q|--quiet      Don't emit any messages except errors/warnings."
      echo "  -v|--verbose    Show verbose output from every build step."
      exit 0
      ;;
    -n|--no-update|--no-updates)
      DO_UPDATE=false
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

if [ "$DO_UPDATE" == true ]; then
  $QUIET || echo "Checking if html-build is up to date..."
  ORIGIN_URL=$(git remote get-url origin)
  git fetch $($VERBOSE || echo "-q") $ORIGIN_URL master
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
read -e -p "Choose 1-5: " choice
if [ "1" = "$choice" ]; then
  read -e -p "Path to your existing clone: "
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
  read -e -p "GitHub username of fork owner: "
  GH_USERNAME=$(echo "$REPLY" | xargs) # trims leading/trailing space
  if [ -z "$GH_USERNAME" ]; then
    chooseRepo
  fi
  echo
  echo "Does a fork already exist at https://github.com/$GH_USERNAME/html?"
  echo
  read -e -p "Y or N? " yn
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
  read -e -p "URL: "
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
      read -e -p "Y or N? " yn
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
  read -e -p "Y or N? " yn
  if [[ "y" = "$yn" || "Y" = "$yn" ]]; then
    git clone $HTML_GIT_CLONE_OPTIONS \
      $($VERBOSE && echo "--verbose" || $QUIET && echo "--quiet") \
      $HTML_REPO $HTML_SOURCE
  else
    unset HTML_SOURCE
    chooseRepo
  fi
}

if [ -z "$HTML_SOURCE" ]; then
  $QUIET || echo "HTML_SOURCE environment variable not set..."
  $QUIET || echo "OK, looking for HTML source file..."
  PARENT_DIR=$(dirname $DIR)
  if [ -f $PARENT_DIR/html/source ]; then
    $QUIET || echo "OK, looked in the $PARENT_DIR/html directory and found HTML source there..."
    HTML_SOURCE=$PARENT_DIR/html
  else
    if [ -f $DIR/html/source ]; then
      $QUIET || echo "OK, looked in the html subdirectory here and found HTML source..."
      HTML_SOURCE=$DIR/html
    else
      # TODO Before giving up, should we maybe also check $HOME/html? Or anywhere else?
      $QUIET || echo "Didn't find the HTML source on your system..."
      chooseRepo
    fi
  fi
else
  $QUIET || echo "HTML_SOURCE environment variable is set to $HTML_SOURCE; looking for HTML source..."
  if [ -f "$HTML_SOURCE/source" ]; then
    $QUIET || echo "OK, looked in the $HTML_SOURCE directory and found HTML source there..."
  else
    $QUIET || echo "Looked in the $HTML_SOURCE directory but didn't find HTML source there..."
    unset HTML_SOURCE
    chooseRepo
  fi
fi
export HTML_SOURCE

rm -rf $HTML_TEMP && mkdir -p $HTML_TEMP
rm -rf $HTML_OUTPUT && mkdir -p $HTML_OUTPUT

if [ -d $HTML_CACHE ]; then
  PREV_BUILD_SHA=$( cat $HTML_CACHE/last-build-sha.txt 2>/dev/null || echo "" )
  CURRENT_BUILD_SHA=$( git rev-parse HEAD )

  if [ "$PREV_BUILD_SHA" != "$CURRENT_BUILD_SHA" ]; then
    $QUIET || echo "Build tools have been updated since last run; clearing the cache"
    DO_UPDATE=true
    rm -rf $HTML_CACHE
    mkdir -p $HTML_CACHE
    echo $CURRENT_BUILD_SHA > $HTML_CACHE/last-build-sha.txt
  fi
else
  mkdir -p $HTML_CACHE
fi

if [ "$DO_UPDATE" == true ] || [ ! -f $HTML_CACHE/caniuse.json ]; then
  rm -f $HTML_CACHE/caniuse.json
  $QUIET || echo "Downloading caniuse data..."
  curl $($VERBOSE || echo "-s") \
    -o $HTML_CACHE/caniuse.json -k \
    https://raw.githubusercontent.com/Fyrd/caniuse/master/data.json
fi

if [ "$DO_UPDATE" == true ] || [ ! -f $HTML_CACHE/w3cbugs.csv ]; then
  rm -f $HTML_CACHE/w3cbugs.csv
  $QUIET || echo "Downloading list of W3C bugzilla bugs..."
  curl $($VERBOSE || echo "-s") \
    -o $HTML_CACHE/w3cbugs.csv \
    'https://www.w3.org/Bugs/Public/buglist.cgi?columnlist=bug_file_loc,short_desc&query_format=advanced&resolution=---&ctype=csv&status_whiteboard=whatwg-resolved&status_whiteboard_type=notregexp&bug_file_loc=http&bug_file_loc_type=substring&product=WHATWG&product=HTML%20WG&product=CSS&product=WebAppsWG'
fi

$QUIET || echo
$QUIET || echo "Generating spec..."
$QUIET || echo
cp -p  entities/out/entities.inc $HTML_CACHE
cp -p  entities/out/entities-dtd.url $HTML_CACHE
cp -p  quotes/out/cldr.inc $HTML_CACHE
perl .pre-process-main.pl $($QUIET && echo "--quiet") < $HTML_SOURCE/source > $HTML_TEMP/source-expanded-1
perl .pre-process-annotate-attributes.pl < $HTML_TEMP/source-expanded-1 > $HTML_TEMP/source-expanded-2 # this one could be merged
perl .pre-process-tag-omission.pl < $HTML_TEMP/source-expanded-2 | perl .pre-process-index-generator.pl > $HTML_TEMP/source-whatwg-complete # this one could be merged

function runWattsi {
  # Input arguments: $1 is the file to run wattsi on, $2 is a directory for wattsi to write output to
  # Output:
  # - Sets global variable $WATTSI_RESULT to an exit code (or equivalent, for HTTP version)
  # - $HTML_TEMP/wattsi-output directory will contain the output from wattsi on success
  # - $HTML_TEMP/wattsi-output.txt will contain the output from wattsi, on both success and failure

  rm -rf $2
  mkdir $2

  if hash wattsi 2>/dev/null; then
    WATTSI_RESULT=$(wattsi $($QUIET && echo "--quiet") $1 $2 \
      $HTML_CACHE/caniuse.json $HTML_CACHE/w3cbugs.csv \
      > $HTML_TEMP/wattsi-output.txt; echo $?)
  else
    $QUIET || echo
    $QUIET || echo "Local wattsi is not present; trying the build server..."

    curl $($VERBOSE && echo "-v") $($QUIET && echo "-s") \
      https://build.whatwg.org/wattsi \
      --form source=@$1 \
      --form caniuse=@$HTML_CACHE/caniuse.json \
      --form w3cbugs=@$HTML_CACHE/w3cbugs.csv \
      --dump-header $HTML_TEMP/wattsi-headers.txt \
      --output $HTML_TEMP/wattsi-output.zip

    # read exit code from the Wattsi-Exit-Code header and assume failure if not found
    WATTSI_RESULT=1
    while IFS=":" read NAME VALUE; do
      if [ "$NAME" == "Wattsi-Exit-Code" ]; then
        WATTSI_RESULT=$(echo $VALUE | tr -d ' \r\n')
        break
      fi
    done < $HTML_TEMP/wattsi-headers.txt

    if [ "$WATTSI_RESULT" != "0" ]; then
      mv $HTML_TEMP/wattsi-output.zip $HTML_TEMP/wattsi-output.txt
    else
      unzip $($VERBOSE && echo "-v" || echo "-qq") $HTML_TEMP/wattsi-output.zip -d $2
      mv $2/output.txt $HTML_TEMP/wattsi-output.txt
    fi
  fi
}

runWattsi $HTML_TEMP/source-whatwg-complete $HTML_TEMP/wattsi-output
if [ "$WATTSI_RESULT" == "0" ]; then
    $QUIET || cat $HTML_TEMP/wattsi-output.txt | grep -v '^$' # trim blank lines
else
  cat $HTML_TEMP/wattsi-output.txt | grep -v '^$' # trim blank lines
  if [ "$WATTSI_RESULT" == "65" ]; then
    echo
    echo "There were errors. Running again to show the original line numbers."
    echo
    runWattsi $HTML_SOURCE/source $HTML_TEMP/wattsi-raw-source-output
    cat $HTML_TEMP/wattsi-output.txt | grep -v '^$' # trim blank lines
  fi
  echo
  echo "There were errors. Stopping."
  exit $WATTSI_RESULT
fi

cat $HTML_TEMP/wattsi-output/index-html | perl .post-process-partial-backlink-generator.pl > $HTML_OUTPUT/index;
cp -p  entities/out/entities.json $HTML_OUTPUT

# multipage setup
rm -rf $HTML_OUTPUT/multipage
mv $HTML_TEMP/wattsi-output/multipage-html $HTML_OUTPUT/multipage
rm -rf $HTML_TEMP

cp -p  $HTML_SOURCE/.htaccess $HTML_OUTPUT
cp -p  $HTML_SOURCE/404.html $HTML_OUTPUT
cp -pR $HTML_SOURCE/fonts $HTML_OUTPUT
cp -pR $HTML_SOURCE/images $HTML_OUTPUT
cp -pR $HTML_SOURCE/demos $HTML_OUTPUT
cp -pR $HTML_SOURCE/link-fixup.js $HTML_OUTPUT

$QUIET || echo
$QUIET || echo "Linting the output..."
# show potential problems
# note - would be nice if the ones with \s+ patterns actually cross lines, but, they don't...
grep -ni 'xxx' $HTML_SOURCE/source| perl -lpe 'print "\nPossible incomplete sections:" if $. == 1'
grep -niE '( (code|span|var)(>| data-x=)|[^<;]/(code|span|var)>)' $HTML_SOURCE/source| perl -lpe 'print "\nPossible copypasta:" if $. == 1'
grep -ni 'chosing\|approprate\|occured\|elemenst\|\bteh\b\|\blabelled\b\|\blabelling\b\|\bhte\b\|taht\|linx\b\|speciication\|attribue\|kestern\|horiontal\|\battribute\s\+attribute\b\|\bthe\s\+the\b\|\bthe\s\+there\b\|\bfor\s\+for\b\|\bor\s\+or\b\|\bany\s\+any\b\|\bbe |be\b\|\bwith\s\+with\b\|\bis\s\+is\b' $HTML_SOURCE/source| perl -lpe 'print "\nPossible typos:" if $. == 1'
perl -ne 'print "$.: $_" if (/\ban (<[^>]*>)*(?!(L\b|http|https|href|hgroup|rb|rp|rt|rtc|li|xml|svg|svgmatrix|hour|hr|xhtml|xslt|xbl|nntp|mpeg|m[ions]|mtext|merror|h[1-6]|xmlns|xpath|s|x|sgml|huang|srgb|rsa|only|option|optgroup)\b|html)[b-df-hj-np-tv-z]/i or /\b(?<![<\/;])a (?!<!--grammar-check-override-->)(<[^>]*>)*(?!&gt|one)(?:(L\b|http|https|href|hgroup|rt|rp|li|xml|svg|svgmatrix|hour|hr|xhtml|xslt|xbl|nntp|mpeg|m[ions]|mtext|merror|h[1-6]|xmlns|xpath|s|x|sgml|huang|srgb|rsa|only|option|optgroup)\b|html|[aeio])/i)' $HTML_SOURCE/source| perl -lpe 'print "\nPossible article problems:" if $. == 1'
grep -ni 'and/or' $HTML_SOURCE/source| perl -lpe 'print "\nOccurrences of making Ms2ger unhappy and/or annoyed:" if $. == 1'
grep -ni 'throw\s\+an\?\s\+<span' $HTML_SOURCE/source| perl -lpe 'print "\nException marked using <span> rather than <code>:" if $. == 1'

$QUIET || echo
$QUIET || echo "Success!"
