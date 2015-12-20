#!/bin/bash
set -e
HTML_GIT_CLONE_OPTIONS=${HTML_GIT_CLONE_OPTIONS:-"--depth 1"}

# Absolute path to the directory containing this script
DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

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

[ -d $HTML_CACHE ]  || mkdir -p $HTML_CACHE

if [ ! -d $HTML_CACHE/cldr-data ]; then
  $QUIET || echo "Checking out CLDR (79 MB)..."
  svn $($VERBOSE && echo "-v") $($QUIET && echo "-q") \
    checkout http://www.unicode.org/repos/cldr/trunk/common/main/ $HTML_CACHE/cldr-data
fi

$QUIET || echo "Examining CLDR (this takes a moment)...";
if [ "$DO_UPDATE" == true ] && [ "`svn info -r HEAD $HTML_CACHE/cldr-data | grep -i "Last Changed Rev"`" != "`svn info $HTML_CACHE/cldr-data | grep -i "Last Changed Rev"`" -o ! -s $HTML_CACHE/cldr.inc ]; then
  $QUIET || echo "Updating CLDR..."
  svn $($QUIET && echo "-q") up $HTML_CACHE/cldr-data;
  perl -T .cldr-processor.pl > $HTML_CACHE/cldr.inc;
fi

if [ "$DO_UPDATE" == true ] || [ ! -f $HTML_CACHE/unicode.xml ]; then
  $QUIET || echo "Downloading unicode.xml (can take a short time, depending on your bandwidth)...";
  curl --location $($VERBOSE && echo "-v") $($QUIET && echo "-s") \
    https://www.w3.org/2003/entities/2007xml/unicode.xml.zip \
    $( [ -f $HTML_CACHE/unicode.xml ] && echo "--time-cond $HTML_CACHE/unicode.xml" ) \
    --output $HTML_TEMP/unicode.xml.zip
  [ -f $HTML_TEMP/unicode.xml.zip ] && unzip $($VERBOSE && echo "-v" || echo "-qq") \
    -o $HTML_TEMP/unicode.xml.zip -d $HTML_CACHE && touch $HTML_CACHE/unicode.xml
fi

# XXX should also check if .entity-processor.py, .entity-processor-json.py, and entities-legacy* have changed
if [ $HTML_CACHE/unicode.xml -nt $HTML_CACHE/entities.inc ]; then
  $QUIET || echo;
  $QUIET || echo "Updating entities database (this always takes a while)...";
  python .entity-processor.py > $HTML_TEMP/new-entities-unicode.inc;
  [ -s $HTML_TEMP/new-entities-unicode.inc ] && mv -f $HTML_TEMP/new-entities-unicode.inc $HTML_TEMP/entities-unicode.inc; # otherwise, probably http error, just do it again next time
  python .entity-processor-json.py > $HTML_TEMP/new-entities-unicode-json.inc;
  [ -s $HTML_TEMP/new-entities-unicode-json.inc ] && mv -f $HTML_TEMP/new-entities-unicode-json.inc $HTML_TEMP/json-entities-unicode.inc; # otherwise, probably http error, just do it again next time
  echo '<tbody>' > $HTML_CACHE/entities.inc
  cat $HTML_SOURCE/entities-*.inc $HTML_TEMP/entities-*.inc | perl -e 'my @lines = <>; print sort { $a =~ m/id="([^"]+?)(-legacy)?"/; $a1 = $1; $a2 = $2; $b =~ m/id="([^"]+?)(-legacy)?"/; $b1 = $1; $b2 = $2; return (lc($a1) cmp lc($b1)) || ($a1 cmp $b1) || ($a2 cmp $b2); } @lines' >> $HTML_CACHE/entities.inc
  echo '{' > $HTML_OUTPUT/entities.json
  cat $HTML_SOURCE/json-entities-* $HTML_TEMP/json-entities-* | sort | perl -e '$/ = undef; $_ = <>; chop, chop, print' >> $HTML_OUTPUT/entities.json
  echo '' >> $HTML_OUTPUT/entities.json
  echo '}' >> $HTML_OUTPUT/entities.json
  perl -Tw .entity-to-dtd.pl < $HTML_TEMP/entities-unicode.inc > $HTML_CACHE/entities-dtd.url
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
  $QUIET || echo "Downloading list of W3C bugzilla bugs (can be a wee bit slow)..."
  curl $($VERBOSE || echo "-s") \
    -o $HTML_CACHE/w3cbugs.csv \
    'https://www.w3.org/Bugs/Public/buglist.cgi?columnlist=bug_file_loc,short_desc&query_format=advanced&resolution=---&ctype=csv&status_whiteboard=whatwg-resolved&status_whiteboard_type=notregexp'
fi

$QUIET || echo
$QUIET || echo "Generating spec..."
$QUIET || echo
perl .pre-process-main.pl $($QUIET && echo "--quiet") < $HTML_SOURCE/source > $HTML_TEMP/source-expanded-1
perl .pre-process-annotate-attributes.pl < $HTML_TEMP/source-expanded-1 > $HTML_TEMP/source-expanded-2 # this one could be merged
perl .pre-process-tag-omission.pl < $HTML_TEMP/source-expanded-2 > $HTML_TEMP/source-whatwg-complete # this one could be merged
mkdir $HTML_TEMP/wattsi-output

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

    HTTP_CODE=`curl $($VERBOSE && echo "-v") $($QUIET && echo "-s")\
      http://ec2-52-88-42-163.us-west-2.compute.amazonaws.com/ \
      --write-out "%{http_code}" \
      --form source=@$1 \
      --form caniuse=@$HTML_CACHE/caniuse.json \
      --form w3cbugs=@$HTML_CACHE/w3cbugs.csv \
      --output $HTML_TEMP/wattsi-output.zip`

    if [ "$HTTP_CODE" != "200" ]; then
      mv $HTML_TEMP/wattsi-output.zip $HTML_TEMP/wattsi-output.txt
      WATTSI_RESULT=1
    else
      unzip $($VERBOSE && echo "-v" || echo "-qq") $HTML_TEMP/wattsi-output.zip -d $HTML_TEMP/wattsi-output
      mv $HTML_TEMP/wattsi-output/output.txt $HTML_TEMP/wattsi-output.txt
      WATTSI_RESULT=0
    fi
  fi
}

runWattsi $HTML_TEMP/source-whatwg-complete $HTML_TEMP/wattsi-output

if [[ ! $QUIET = "true" || ! "$WATTSI_RESULT" = "0" ]]; then
  mv $HTML_TEMP/wattsi-output.txt $HTML_TEMP/wattsi-first-pass-output.txt
  cp $HTML_SOURCE/source $HTML_TEMP/raw-source
  # suppress 'missing <dfn> for topic "sort parser mode: separator"' error
  perl -pi -e 's|^\s+</body>|<dfn w-drop data-x="sort parser mode: separator"></dfn></body>|' $HTML_TEMP/raw-source
  runWattsi $HTML_TEMP/raw-source $HTML_TEMP/wattsi-raw-source-output

  echo
  cat $HTML_TEMP/wattsi-first-pass-output.txt | grep -v '^$' # trim blank lines

  echo
  echo "For any error messages with line numbers, the messages are repeated below,"
  echo "but with correct line numbers from the $HTML_SOURCE/source file."
  echo
  cat $HTML_TEMP/wattsi-output.txt | grep -v '^$' # trim blank lines
  if [[ ! "$WATTSI_RESULT" = "0" ]]; then
    echo
    echo "Found fatal errors. Stopping."
    exit 1
  fi
fi

cat $HTML_TEMP/wattsi-output/index-html | perl .post-process-index-generator.pl | perl .post-process-partial-backlink-generator.pl > $HTML_OUTPUT/index;

# multipage setup
ln -s ../images $HTML_TEMP/wattsi-output/multipage-html/
ln -s ../link-fixup.js $HTML_TEMP/wattsi-output/multipage-html/
ln -s ../entities.json $HTML_TEMP/wattsi-output/multipage-html/

rm -rf $HTML_OUTPUT/multipage
mv $HTML_TEMP/wattsi-output/multipage-html $HTML_OUTPUT/multipage
rm -rf $HTML_TEMP

cp -p  $HTML_SOURCE/.htaccess $HTML_OUTPUT
cp -p  $HTML_SOURCE/404.html $HTML_OUTPUT
cp -pR $HTML_SOURCE/fonts $HTML_OUTPUT
cp -pR $HTML_SOURCE/images $HTML_OUTPUT
cp -pR $HTML_SOURCE/link-fixup.js $HTML_OUTPUT

$QUIET || echo
$QUIET || echo "Linting the output..."
# show potential problems
# note - would be nice if the ones with \s+ patterns actually cross lines, but, they don't...
grep -ni 'xxx' $HTML_SOURCE/source| perl -lpe 'print "\nPossible incomplete sections:" if $. == 1'
egrep -ni '( (code|span|var)(>| data-x=)|[^<;]/(code|span|var)>)' $HTML_SOURCE/source| perl -lpe 'print "\nPossible copypasta:" if $. == 1'
grep -ni 'chosing\|approprate\|occured\|elemenst\|\bteh\b\|\blabelled\b\|\blabelling\b\|\bhte\b\|taht\|linx\b\|speciication\|attribue\|kestern\|horiontal\|\battribute\s\+attribute\b\|\bthe\s\+the\b\|\bthe\s\+there\b\|\bfor\s\+for\b\|\bor\s\+or\b\|\bany\s\+any\b\|\bbe |be\b\|\bwith\s\+with\b\|\bis\s\+is\b' $HTML_SOURCE/source| perl -lpe 'print "\nPossible typos:" if $. == 1'
perl -ne 'print "$.: $_" if (/\ban (<[^>]*>)*(?!(L\b|http|https|href|hgroup|rb|rp|rt|rtc|li|xml|svg|svgmatrix|hour|hr|xhtml|xslt|xbl|nntp|mpeg|m[ions]|mtext|merror|h[1-6]|xmlns|xpath|s|x|sgml|huang|srgb|rsa|only|option|optgroup)\b|html)[b-df-hj-np-tv-z]/i or /\b(?<![<\/;])a (?!<!--grammar-check-override-->)(<[^>]*>)*(?!&gt|one)(?:(L\b|http|https|href|hgroup|rt|rp|li|xml|svg|svgmatrix|hour|hr|xhtml|xslt|xbl|nntp|mpeg|m[ions]|mtext|merror|h[1-6]|xmlns|xpath|s|x|sgml|huang|srgb|rsa|only|option|optgroup)\b|html|[aeio])/i)' $HTML_SOURCE/source| perl -lpe 'print "\nPossible article problems:" if $. == 1'
grep -ni 'and/or' $HTML_SOURCE/source| perl -lpe 'print "\nOccurrences of making Ms2ger unhappy and/or annoyed:" if $. == 1'
grep -ni 'throw\s\+an\?\s\+<span' $HTML_SOURCE/source| perl -lpe 'print "\nException marked using <span> rather than <code>:" if $. == 1'

$QUIET || echo
$QUIET || echo "Success!"
