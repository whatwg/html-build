#!/bin/bash

if [ "`svn info -r HEAD .cldr-data | grep -i "Last Changed Rev"`" != "`svn info .cldr-data | grep -i "Last Changed Rev"`" -o ! -s cldr.inc ]; then
  echo;
  echo Updating CLDR...;
  svn up .cldr-data;
  perl -T .cldr-processor.pl > cldr.inc;
fi

wget -o /dev/null -N http://www.w3.org/2003/entities/2007xml/unicode.xml
# XXX should also check if .entity-processor.py, .entity-processor-json.py, and entities-legacy* have changed
if [ unicode.xml -nt entities-unicode.inc ]; then
  echo;
  echo Updating entities database...;
  python .entity-processor.py > .new-entities-unicode.inc;
  [ -s .new-entities-unicode.inc ] && mv -f .new-entities-unicode.inc entities-unicode.inc; # otherwise, probably http error, just do it again next time
  python .entity-processor-json.py > .new-entities-unicode-json.inc;
  [ -s .new-entities-unicode-json.inc ] && mv -f .new-entities-unicode-json.inc json-entities-unicode.inc; # otherwise, probably http error, just do it again next time
  echo '<tbody>' > entities.inc
  rm -f entities-dtd.url entities*~ json-*~ json-entities.inc
  cat entities-*.inc | perl -e 'my @lines = <>; print sort { $a =~ m/id="([^"]+?)(-legacy)?"/; $a1 = $1; $a2 = $2; $b =~ m/id="([^"]+?)(-legacy)?"/; $b1 = $1; $b2 = $2; return (lc($a1) cmp lc($b1)) || ($a1 cmp $b1) || ($a2 cmp $b2); } @lines' >> entities.inc
  echo '{' > entities.json
  cat json-entities-* | sort | perl -e '$/ = undef; $_ = <>; chop, chop, print' >> entities.json
  echo '' >> entities.json
  echo '}' >> entities.json
  perl -Tw .entity-to-dtd.pl < entities-unicode.inc > entities-dtd.url
fi

rm -rf caniuse.json w3cbugs.csv
wget -o /dev/null -O caniuse.json --no-check-certificate https://raw.githubusercontent.com/Fyrd/caniuse/master/data.json
wget -o /dev/null -O w3cbugs.csv 'https://www.w3.org/Bugs/Public/buglist.cgi?columnlist=bug_file_loc,short_desc&query_format=advanced&resolution=---&ctype=csv'

echo "Generating spec..."
rm -rf source-* .source* .wattsi-*
perl .pre-process-main.pl < source > .source-expanded-1 || exit
perl .pre-process-annotate-attributes.pl < .source-expanded-1 > .source-expanded-2 || exit # this one could be merged
perl .pre-process-tag-omission.pl < .source-expanded-2 > source-whatwg-complete || exit # this one could be merged
rm -f .source*
mkdir .wattsi-output || exit

if [ -e "wattsi" ] ; then
  wattsi source-whatwg-complete .wattsi-output caniuse.json w3cbugs.csv || exit
else
  echo "Local wattsi is not present; trying the build server..."

  HTTP_CODE=`curl http://ec2-52-88-42-163.us-west-2.compute.amazonaws.com/ \
        --write-out "%{http_code}" \
        --form source=@source-whatwg-complete \
        --form caniuse=@caniuse.json \
        --form w3cbugs=@w3cbugs.csv \
        --output .wattsi-output.zip`

  if [ "$HTTP_CODE" != "200" ]; then
      cat .wattsi-output.zip
      rm .wattsi-output.zip
      exit 22
  fi

  unzip .wattsi-output.zip -d .wattsi-output
  rm .wattsi-output.zip
fi

rm -f complete.html
cat .wattsi-output/index-html | perl .post-process-index-generator.pl | perl .post-process-partial-backlink-generator.pl > complete.html;

# multipage setup
ln -s ../images .wattsi-output/multipage-html/
ln -s ../link-fixup.js .wattsi-output/multipage-html/
ln -s ../entities.json .wattsi-output/multipage-html/
echo "ErrorDocument 404 /multipage/404.html" > .wattsi-output/multipage-html/.htaccess
echo "<files *.txt>" >> .wattsi-output/multipage-html/.htaccess
echo " ForceType text/plain" >> .wattsi-output/multipage-html/.htaccess
echo "</files>" >> .wattsi-output/multipage-html/.htaccess
echo "<files *.js>" >> .wattsi-output/multipage-html/.htaccess
echo " ForceType text/javascript" >> .wattsi-output/multipage-html/.htaccess
echo "</files>" >> .wattsi-output/multipage-html/.htaccess
echo "<files *.css>" >> .wattsi-output/multipage-html/.htaccess
echo " ForceType text/css" >> .wattsi-output/multipage-html/.htaccess
echo "</files>" >> .wattsi-output/multipage-html/.htaccess
echo "<files *.html>" >> .wattsi-output/multipage-html/.htaccess
echo " ForceType text/html" >> .wattsi-output/multipage-html/.htaccess
echo "</files>" >> .wattsi-output/multipage-html/.htaccess
cp .multipage-404 .wattsi-output/multipage-html/404.html

rm -rf multipage index
cp complete.html index
mv .wattsi-output/multipage-html multipage

# show potential problems
# note - would be nice if the ones with \s+ patterns actually cross lines, but, they don't...
grep -ni 'xxx' source | perl -lpe 'print "\nPossible incomplete sections:" if $. == 1'
egrep -ni '( (code|span|var)(>| data-x=)|[^<;]/(code|span|var)>)' source | perl -lpe 'print "\nPossible copypasta:" if $. == 1'
grep -ni 'chosing\|approprate\|occured\|elemenst\|\bteh\b\|\blabelled\b\|\blabelling\b\|\bhte\b\|taht\|linx\b\|speciication\|attribue\|kestern\|horiontal\|\battribute\s\+attribute\b\|\bthe\s\+the\b\|\bthe\s\+there\b\|\bfor\s\+for\b\|\bor\s\+or\b\|\bany\s\+any\b\|\bbe |be\b\|\bwith\s\+with\b\|\bis\s\+is\b' source | perl -lpe 'print "\nPossible typos:" if $. == 1'
perl -ne 'print "$.: $_" if (/\ban (<[^>]*>)*(?!(L\b|http|https|href|hgroup|rt|rp|li|xml|svg|svgmatrix|hour|hr|xhtml|xslt|xbl|nntp|mpeg|m[ions]|mtext|merror|h[1-6]|xmlns|xpath|s|x|sgml|huang|srgb|rsa|only|option|optgroup)\b|html)[b-df-hj-np-tv-z]/i or /\b(?<![<\/;])a (?!<!--grammar-check-override-->)(<[^>]*>)*(?!&gt|one)(?:(L\b|http|https|href|hgroup|rt|rp|li|xml|svg|svgmatrix|hour|hr|xhtml|xslt|xbl|nntp|mpeg|m[ions]|mtext|merror|h[1-6]|xmlns|xpath|s|x|sgml|huang|srgb|rsa|only|option|optgroup)\b|html|[aeio])/i)' source | perl -lpe 'print "\nPossible article problems:" if $. == 1'
grep -ni 'and/or' source | perl -lpe 'print "\nOccurrences of making Ms2ger unhappy and/or annoyed:" if $. == 1'
grep -ni 'throw\s\+an\?\s\+<span' source | perl -lpe 'print "\nException marked using <span> rather than <code>:" if $. == 1'
