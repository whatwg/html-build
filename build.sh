#!/bin/bash
set -e
HTML_GIT_CLONE_OPTIONS=${HTML_GIT_CLONE_OPTIONS:-"--depth 1"}
WATTSI_SERVER=${WATTSI_SERVER:-http://ec2-52-88-42-163.us-west-2.compute.amazonaws.com/}
export WATTSI_SERVER

# Absolute path to the directory containing this script
DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

# Used in colorizing a few messages, for better UX.
CFAIL="\033[1;31m"
CSUCCESS="\033[0;32m"
CNOTE="\033[0;33m"
CHIGHLIGHT="\033[0;35m"
COLOROFF="\033[0m"

# DO_INSTALL is an internal flag we set to false only in remote-build environment
DO_INSTALL=true
DO_UPDATE=true
VERBOSE=false
QUIET=false
REMOTE=false
ZIP_SOURCE=true
export DO_UPDATE
export VERBOSE
export QUIET
export REMOTE
export ZIP_SOURCE

for arg in "$@"
do
  case $arg in
    -c|--clean)
      rm -rf $HTML_CACHE
      exit 0
      ;;
    -h|--help)
      echo "Usage: $0 [-d|--delete]"
      echo "       $0 [-h|--help]"
      echo
      echo "   For default (remote) builds:"
      echo "       $0"
      echo "            [-p|--plain]|[-z|--zip] [-q|--quiet] [-r|--remote [HOST] ]"
      echo "            [-v|--verbose] [SOURCE]"
      echo
      echo "   For Wattsi-enabled (local) builds:"
      echo "       $0 [-n|--no-update] [-q|--quiet] [-v|--verbose] [SOURCE]"
      echo
      echo "   For more control over where build files get written:"
      echo "       $0"
      echo "            [-c|--cache CACHE ] [-l|--log LOG] [-n|--no-update]"
      echo "            [-o|--output OUT] [-q|--quiet] [-t|--temp TEMP]"
      echo "            [-v|--verbose] [SOURCE]"
      echo
      echo "  -c|--cache CACHE    Use cache directory CACHE; default: .cache"
      echo "  -d|--delete         Delete downloaded dependencies/generated files, then stop."
      echo "  -h|--help           Show this usage statement."
      echo "  -l|--log LOG        Use log directory LOG; default: output"
      echo "  -n|--no-update      Don't update before building; just build."
      echo "  -o|--output OUT     Write output files to directory OUT; default: output"
      echo "  -p|--plain          Send plain-text source to build server; don't zip it."
      echo "  -q|--quiet          Don't emit any messages except errors/warnings."
      echo "  -r|--remote [HOST]  Do a remote build using host HOST as the build server."
      echo "  -s|--skip-install   Don't \"install\" into output directory after building."
      echo "  -t|--temp TEMP      Use temp directory TEMP; default: .temp"
      echo "  -v|--verbose        Show verbose output from every build step."
      echo "  -z|--zip-source     Zip source before sending to build server; default: true."
      echo "  SOURCE              Source file (HTML spec) to build from."
      exit 0
      ;;
    -c|--cache)
      HTML_CACHE=$2
      shift 2
      ;;
    -n|--no-update|--no-updates)
      DO_UPDATE=false
      shift
      ;;
    -l|--log)
      HTML_LOG=$2
      shift 2
      ;;
    -o|--output)
      HTML_OUTPUT=$2
      shift 2
      ;;
    -p|--plain)
      ZIP_SOURCE=false
      shift
      ;;
    -q|--quiet)
      QUIET=true
      VERBOSE=false
      shift
      ;;
    -r|--remote)
      REMOTE=true
      if [[ $2 == *":"* ]]; then
        WATTSI_SERVER=$2
        shift 2
      else
        shift
      fi
      ;;
    -s|--skip-install)
      DO_INSTALL=false
      shift
      ;;
    -t|--temp)
      HTML_TEMP=$2
      shift 2
      ;;
    -v|--verbose)
      VERBOSE=true
      QUIET=false
      set -vx
      shift
      ;;
    -z|--zip)
      ZIP_SOURCE=true
      shift
      ;;
    *)
      HTML_SOURCE=$arg
      ;;
  esac
done

function cloneHtml {
  HTML_SOURCE=${HTML_SOURCE:-$DIR/html/source}
  git clone $HTML_GIT_CLONE_OPTIONS \
    $($VERBOSE && echo "--verbose" || $QUIET && echo "--quiet") \
    https://github.com/whatwg/html.git $(dirname $HTML_SOURCE)
}
if [ -z "$HTML_SOURCE" ]; then
  $QUIET || echo "No source file specified on command line, and HTML_SOURCE not set..."
  $QUIET || echo "OK, looking for HTML source file..."
  PARENT_DIR=$(dirname $DIR)
  if [ -f $PARENT_DIR/html/source ]; then
    $QUIET || echo "OK, looked in the $PARENT_DIR/html directory and found HTML source there..."
    HTML_SOURCE=$PARENT_DIR/html/source
  else
    if [ -f $DIR/html/source ]; then
      $QUIET || echo "OK, looked in the html subdirectory here and found HTML source..."
      HTML_SOURCE=$DIR/html/source
    else
      $QUIET || echo "Didn't find the HTML source on your system..."
      $QUIET || echo "OK, cloning it..."
      cloneHtml
    fi
  fi
else
  if [ -f "$HTML_SOURCE" ]; then
    if [ "$QUIET" = false ]; then
      # Quiet because, don't pointlessly leak server-side temp path/file names.
      [ "$DO_INSTALL" = true ] && echo "OK, will build with $HTML_SOURCE as the source..."
    fi
  else
    $QUIET || echo "Didn't find a $HTML_SOURCE file..."
    cloneHtml
  fi
fi

# The steps in this do_install function need to run at the end of the build
# in the local environment of the user, but not on the build server. So when
# doing remote builds, DO_INSTALL gets set to false, to suppress these steps.
function do_install {
  if [ "$DO_INSTALL" != false ]; then
    cp -p  $(dirname $HTML_SOURCE)/.htaccess $HTML_OUTPUT
    cp -p  $(dirname $HTML_SOURCE)/404.html $HTML_OUTPUT
    cp -pR $(dirname $HTML_SOURCE)/fonts $HTML_OUTPUT
    cp -pR $(dirname $HTML_SOURCE)/images $HTML_OUTPUT
    cp -pR $(dirname $HTML_SOURCE)/link-fixup.js $HTML_OUTPUT

    # multipage setup
    ln -s ../images $HTML_TEMP/wattsi-output/multipage-html/
    ln -s ../link-fixup.js $HTML_TEMP/wattsi-output/multipage-html/
    ln -s ../entities.json $HTML_TEMP/wattsi-output/multipage-html/

    rm -rf $HTML_OUTPUT/multipage
    mv $HTML_TEMP/wattsi-output/index $HTML_OUTPUT
    mv $HTML_TEMP/wattsi-output/multipage-html $HTML_OUTPUT/multipage
    rm -rf $HTML_TEMP
    $QUIET || echo -e "${CNOTE}Your output is in the ${CSUCCESS}$HTML_OUTPUT${CNOTE} directory.${COLOROFF}"
  fi
}

export HTML_SOURCE

HTML_CACHE=${HTML_CACHE:-$DIR/.cache}
export HTML_CACHE

HTML_TEMP=${HTML_TEMP:-$DIR/.temp}
export HTML_TEMP

HTML_OUTPUT=${HTML_OUTPUT:-$DIR/output}
export HTML_OUTPUT

HTML_LOG=${HTML_LOG:-$DIR/output}
export HTML_LOG

rm -rf $HTML_TEMP && mkdir -p $HTML_TEMP
rm -rf $HTML_OUTPUT && mkdir -p $HTML_OUTPUT

# From here on, all of stdout and stderr get echoed to the build.log file.
# We need this in order to get back a useful build log for remote builds.
exec > >(tee $HTML_LOG/build.log)
exec 2>&1

if [ "0" == "$(hash wattsi 2>/dev/null)" ] || [ "$REMOTE" = true ]; then

  if [ "$ZIP_SOURCE" = true ]; then
    zip -j $($VERBOSE && echo "-v" || echo "-qq") $HTML_TEMP/source.zip $HTML_SOURCE
  fi

  $QUIET || echo
  $QUIET || echo -e "${CSUCCESS}The build server at $WATTSI_SERVER is now running your build..."
  $QUIET || echo -e "${CNOTE}Please wait while the build completes. It can take ${CHIGHLIGHT}90 seconds or more ☕ ...${COLOROFF}"
  $QUIET || echo

  HTTP_CODE=$(curl $($VERBOSE && echo "-v") $($QUIET && echo "-s") \
        $WATTSI_SERVER \
        $($VERBOSE && echo "--form verbose=verbose") \
        $($QUIET && echo "--form quiet=quiet") \
        --write-out "%{http_code}" \
        --output $HTML_TEMP/wattsi-output.zip \
        --form source=@$([ "$ZIP_SOURCE" = true ] && echo "$HTML_TEMP/source.zip" || echo $HTML_SOURCE))

  if [ "$HTTP_CODE" != "200" ]; then
      cat $HTML_TEMP/wattsi-output.zip
      rm -f $HTML_TEMP/wattsi-output.zip
      exit 22
  fi

  unzip $($QUIET && echo "-qq") $HTML_TEMP/wattsi-output.zip -d $HTML_TEMP/wattsi-output
  mv $HTML_TEMP/wattsi-output/entities.json $HTML_OUTPUT
  cat $HTML_TEMP/wattsi-output/build.log
  do_install
  exit
fi

[ -d $HTML_TEMP ]   || mkdir -p $HTML_TEMP
[ -d $HTML_CACHE ]  || mkdir -p $HTML_CACHE

if [ ! -d $HTML_CACHE/cldr-data ]; then
  $QUIET || echo "Checking out CLDR (79 MB)..."
  # Quiet because, don't pointlessly leak server-side temp path/file names.
  svn $($DO_INSTALL || echo "-q") $($QUIET && echo "-q") \
    checkout http://www.unicode.org/repos/cldr/trunk/common/main/ $HTML_CACHE/cldr-data
fi

$QUIET || echo "Examining CLDR (this takes a moment)...";
if [ "$DO_UPDATE" == true ] && [ "`svn info -r HEAD $HTML_CACHE/cldr-data | grep -i "Last Changed Rev"`" != "`svn info $HTML_CACHE/cldr-data | grep -i "Last Changed Rev"`" -o ! -s $HTML_CACHE/cldr.inc ]; then
  $QUIET || echo "Updating CLDR..."
  svn $($DO_INSTALL || echo "-q") $($QUIET && echo "-q") \
    up $HTML_CACHE/cldr-data;
  perl -T .cldr-processor.pl > $HTML_CACHE/cldr.inc;
fi

if [ "$DO_UPDATE" == true ] || [ ! -f $HTML_CACHE/unicode.xml ]; then
  $QUIET || echo "Downloading unicode.xml (can take a short time, depending on your bandwith)...";
  curl --location $($VERBOSE && echo "-v") $($QUIET && echo "-s") \
    https://www.w3.org/2003/entities/2007xml/unicode.xml.zip \
    $( [ -f $HTML_CACHE/unicode.xml ] && echo "--time-cond $HTML_CACHE/unicode.xml" ) \
    --output $HTML_TEMP/unicode.xml.zip
  # Quiet because, don't pointlessly leak server-side temp path/file names.
  [ -f $HTML_TEMP/unicode.xml.zip ] && unzip $($DO_INSTALL || echo "-qq") $($QUIET && echo "-qq") \
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
  cat $HTML_TEMP/entities-*.inc | perl -e 'my @lines = <>; print sort { $a =~ m/id="([^"]+?)(-legacy)?"/; $a1 = $1; $a2 = $2; $b =~ m/id="([^"]+?)(-legacy)?"/; $b1 = $1; $b2 = $2; return (lc($a1) cmp lc($b1)) || ($a1 cmp $b1) || ($a2 cmp $b2); } @lines' >> $HTML_CACHE/entities.inc
  echo '{' > $HTML_OUTPUT/entities.json
  cat $HTML_TEMP/json-entities-* | sort | perl -e '$/ = undef; $_ = <>; chop, chop, print' >> $HTML_OUTPUT/entities.json
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
    'https://www.w3.org/Bugs/Public/buglist.cgi?columnlist=bug_file_loc,short_desc&query_format=advanced&resolution=---&ctype=csv'
fi

$QUIET || echo
$QUIET || echo "Generating spec..."
$QUIET || echo
perl .pre-process-main.pl $($QUIET && echo "--quiet") < $HTML_SOURCE > $HTML_TEMP/source-expanded-1
perl .pre-process-annotate-attributes.pl < $HTML_TEMP/source-expanded-1 > $HTML_TEMP/source-expanded-2 # this one could be merged
perl .pre-process-tag-omission.pl < $HTML_TEMP/source-expanded-2 > $HTML_TEMP/source-whatwg-complete # this one could be merged
mkdir $HTML_TEMP/wattsi-output

function rerunWattsi {
  # If we end up here it means that wattsi exited non-zero, probably with
  # one or more error messages that include line and column numbers; e.g.:
  #     Parse Error:(748,59) unexpected end tag
  # But in that case, the line numbers that wattsi reports are for lines in
  # the copy of the source produced by running the original through the
  # pre-processer steps above. Therefore, the reported line numbers may be
  # wrong, so here we re-run wattsi against the original source to get the
  # correct line numbers.
  echo > $HTML_TEMP/parse.log
  echo "Line numbers in any error messages above may be wrong." >> $HTML_TEMP/parse.log
  echo "The correct line numbers for errors in your $([ "$DO_INSTALL" = true ] && echo $HTML_SOURCE || echo source) file are shown below." >> $HTML_TEMP/parse.log
  echo >> $HTML_TEMP/parse.log
  WATTSI_OUTPUT2=$HTML_TEMP/wattsi-output-original-source
  mkdir $WATTSI_OUTPUT2
  # XXX make this call to wattsi always be quiet after wattsi patch lands
  wattsi $($QUIET && echo "--quiet") \
    $HTML_SOURCE $WATTSI_OUTPUT2 \
    $HTML_CACHE/caniuse.json $HTML_CACHE/w3cbugs.csv \
    >> $HTML_TEMP/parse.log || cat $HTML_TEMP/parse.log
    # unless this 2nd call to wattsi also exits non-zero, there aren't
    # actually any error messages in the source to report, and so the line
    # numbers reported during the first pass must be correct, and must
    # indicate some problem introduced during pre-processing.
  echo
  echo -e "${CFAIL}Build failed.${COLOROFF}"
}

wattsi $($QUIET && echo "--quiet") \
  $HTML_TEMP/source-whatwg-complete $HTML_TEMP/wattsi-output \
  $HTML_CACHE/caniuse.json $HTML_CACHE/w3cbugs.csv || (rerunWattsi; exit 1)

cat $HTML_TEMP/wattsi-output/index-html \
  | perl .post-process-index-generator.pl \
  | perl .post-process-partial-backlink-generator.pl \
  > $HTML_TEMP/wattsi-output/index;

$QUIET || echo
$QUIET || echo "Checking for potential problems..."
# show potential problems
# note - would be nice if the ones with \s+ patterns actually cross lines, but, they don't...
grep -ni 'xxx' $HTML_SOURCE| perl -lpe 'print "\nPossible incomplete sections:" if $. == 1'
egrep -ni '( (code|span|var)(>| data-x=)|[^<;]/(code|span|var)>)' $HTML_SOURCE| perl -lpe 'print "\nPossible copypasta:" if $. == 1'
grep -ni 'chosing\|approprate\|occured\|elemenst\|\bteh\b\|\blabelled\b\|\blabelling\b\|\bhte\b\|taht\|linx\b\|speciication\|attribue\|kestern\|horiontal\|\battribute\s\+attribute\b\|\bthe\s\+the\b\|\bthe\s\+there\b\|\bfor\s\+for\b\|\bor\s\+or\b\|\bany\s\+any\b\|\bbe |be\b\|\bwith\s\+with\b\|\bis\s\+is\b' $HTML_SOURCE| perl -lpe 'print "\nPossible typos:" if $. == 1'
perl -ne 'print "$.: $_" if (/\ban (<[^>]*>)*(?!(L\b|http|https|href|hgroup|rb|rp|rt|rtc|li|xml|svg|svgmatrix|hour|hr|xhtml|xslt|xbl|nntp|mpeg|m[ions]|mtext|merror|h[1-6]|xmlns|xpath|s|x|sgml|huang|srgb|rsa|only|option|optgroup)\b|html)[b-df-hj-np-tv-z]/i or /\b(?<![<\/;])a (?!<!--grammar-check-override-->)(<[^>]*>)*(?!&gt|one)(?:(L\b|http|https|href|hgroup|rt|rp|li|xml|svg|svgmatrix|hour|hr|xhtml|xslt|xbl|nntp|mpeg|m[ions]|mtext|merror|h[1-6]|xmlns|xpath|s|x|sgml|huang|srgb|rsa|only|option|optgroup)\b|html|[aeio])/i)' $HTML_SOURCE| perl -lpe 'print "\nPossible article problems:" if $. == 1'
grep -ni 'and/or' $HTML_SOURCE| perl -lpe 'print "\nOccurrences of making Ms2ger unhappy and/or annoyed:" if $. == 1'
grep -ni 'throw\s\+an\?\s\+<span' $HTML_SOURCE| perl -lpe 'print "\nException marked using <span> rather than <code>:" if $. == 1'

do_install

$QUIET || echo -e "${CSUCCESS}"
$QUIET || echo -n -e "Success! ${COLOROFF}"
