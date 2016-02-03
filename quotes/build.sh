#!/bin/bash
set -e

# cd to the directory containing this script
cd "$( dirname "${BASH_SOURCE[0]}" )"

VERBOSE=false
QUIET=false
QUOTES_TEMP=${QUOTES_TEMP:-.temp}
QUOTES_OUTPUT=${QUOTES_OUTPUT:-out}

for arg in "$@"
do
  case $arg in
    -h|--help)
      echo "Usage: $0 [-h|--help]"
      echo "Usage: $0 [-q|--quiet] [-v|--verbose]"
      echo
      echo "  -h|--help       Show this usage statement."
      echo "  -q|--quiet      Don't emit any messages except errors/warnings."
      echo "  -v|--verbose    Show verbose output from every build step."
      exit 0
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

rm -rf $QUOTES_TEMP && mkdir -p $QUOTES_TEMP
rm -rf $QUOTES_OUTPUT && mkdir -p $QUOTES_OUTPUT

$QUIET || echo "Checking out CLDR (79 MB)..."
svn $($VERBOSE && echo "-v") $($QUIET && echo "-q") \
  checkout http://www.unicode.org/repos/cldr/trunk/common/main/ $QUOTES_TEMP/cldr-data

$QUIET || echo "Generating quotes stylesheet..."
perl -T cldr-processor.pl $($QUIET && echo "--quiet") \
  $QUOTES_TEMP/cldr-data/*.xml > $QUOTES_OUTPUT/cldr.inc;

rm -rf $QUOTES_TEMP
