#!/bin/bash
set -e

# cd to the directory containing this script
cd "$( dirname "${BASH_SOURCE[0]}" )"

VERBOSE=false
QUIET=false
ENTITIES_TEMP=${ENTITIES_TEMP:-.temp}

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

rm -rf $ENTITIES_TEMP && mkdir -p $ENTITIES_TEMP
rm -rf entities-dtd.url entities.inc entities.json

# Fetch unicode.xml
$QUIET || echo "Downloading unicode.xml (can take a short time, depending on your bandwidth)...";
curl $($VERBOSE && echo "-v") $($QUIET && echo "-s") \
  https://raw.githubusercontent.com/w3c/xml-entities/gh-pages/unicode.xml \
  --output $ENTITIES_TEMP/unicode.xml

# Generate entity files
$QUIET || echo;
$QUIET || echo "Generating entities (this always takes a while)...";
python entity-processor.py < $ENTITIES_TEMP/unicode.xml > $ENTITIES_TEMP/new-entities-unicode.inc;
[ -s $ENTITIES_TEMP/new-entities-unicode.inc ] && mv -f $ENTITIES_TEMP/new-entities-unicode.inc $ENTITIES_TEMP/entities-unicode.inc; # otherwise, probably http error, just do it again next time
python entity-processor-json.py < $ENTITIES_TEMP/unicode.xml > $ENTITIES_TEMP/new-entities-unicode-json.inc;
[ -s $ENTITIES_TEMP/new-entities-unicode-json.inc ] && mv -f $ENTITIES_TEMP/new-entities-unicode-json.inc $ENTITIES_TEMP/json-entities-unicode.inc; # otherwise, probably http error, just do it again next time
echo '<tbody>' > entities.inc
cat entities-*.inc $ENTITIES_TEMP/entities-*.inc | perl -e 'my @lines = <>; print sort { $a =~ m/id="([^"]+?)(-legacy)?"/; $a1 = $1; $a2 = $2; $b =~ m/id="([^"]+?)(-legacy)?"/; $b1 = $1; $b2 = $2; return (lc($a1) cmp lc($b1)) || ($a1 cmp $b1) || ($a2 cmp $b2); } @lines' >> entities.inc
echo '{' > entities.json
cat json-entities-* $ENTITIES_TEMP/json-entities-* | sort | perl -e '$/ = undef; $_ = <>; chop, chop, print' >> entities.json
echo '' >> entities.json
echo '}' >> entities.json
perl -Tw entity-to-dtd.pl < $ENTITIES_TEMP/entities-unicode.inc > entities-dtd.url

rm -rf $ENTITIES_TEMP
