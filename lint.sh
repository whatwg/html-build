#!/bin/bash
set -e

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 path/to/html/source"
  exit 1
fi

# show potential problems
# note - would be nice if the ones with \s+ patterns actually cross lines, but, they don't...
MATCHES=$(grep -ni 'xxx' $1 | perl -lpe 'print "\nPossible incomplete sections:" if $. == 1'
  grep -niE '( (code|span|var)(>| data-x=)|[^<;]/(code|span|var)>)' $1 | perl -lpe 'print "\nPossible copypasta:" if $. == 1'
  grep -ni 'chosing\|approprate\|occured\|elemenst\|\bteh\b\|\blabelled\b\|\blabelling\b\|\bhte\b\|taht\|linx\b\|speciication\|attribue\|kestern\|horiontal\|\battribute\s\+attribute\b\|\bthe\s\+the\b\|\bthe\s\+there\b\|\bfor\s\+for\b\|\bor\s\+or\b\|\bany\s\+any\b\|\bbe |be\b\|\bwith\s\+with\b\|\bis\s\+is\b' $1 | perl -lpe 'print "\nPossible typos:" if $. == 1'
  perl -ne 'print "$.: $_" if (/\ban (<[^>]*>)*(?!(L\b|http|https|href|hgroup|rb|rp|rt|rtc|li|xml|svg|svgmatrix|hour|hr|xhtml|xslt|xbl|nntp|mpeg|m[ions]|mtext|merror|h[1-6]|xmlns|xpath|s|x|sgml|huang|srgb|rsa|only|option|optgroup)\b|html)[b-df-hj-np-tv-z]/i or /\b(?<![<\/;])a (?!<!--grammar-check-override-->)(<[^>]*>)*(?!&gt|one)(?:(L\b|http|https|href|hgroup|rt|rp|li|xml|svg|svgmatrix|hour|hr|xhtml|xslt|xbl|nntp|mpeg|m[ions]|mtext|merror|h[1-6]|xmlns|xpath|s|x|sgml|huang|srgb|rsa|only|option|optgroup)\b|html|[aeio])/i)' $1 | perl -lpe 'print "\nPossible article problems:" if $. == 1'
  grep -ni 'and/or' $1 | perl -lpe 'print "\nOccurrences of making Ms2ger unhappy and/or annoyed:" if $. == 1'
  grep -ni 'throw\s\+an\?\s\+<span' $1 | perl -lpe 'print "\nException marked using <span> rather than <code>:" if $. == 1')

if [ -n "$MATCHES" ]; then
  echo "$MATCHES"
  exit 1
fi
