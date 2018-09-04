#!/bin/bash
set -e

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 path/to/html/source"
  exit 1
fi

# show potential problems
MATCHES=$(grep -ni 'xxx' "$1" | perl -lpe 'print "\nPossible incomplete sections:" if $. == 1'
  grep -niE '( (code|span|var)(>| data-x=)|[^<;]/(code|span|var)>)' "$1" | perl -lpe 'print "\nPossible copypasta:" if $. == 1'
  perl -ne '$/ = "\n\n"; print "$_" if (/chosing|approprate|occured|elemenst|\bteh\b|\blabelled\b|\blabelling\b|\bhte\b|taht|linx\b|speciication|attribue|kestern|horiontal|\battribute\s+attribute\b|\bthe\s+the\b|\bthe\s+there\b|\bfor\s+for\b|\bor\s+or\b|\bany\s+any\b|\bbe\s+be\b|\bwith\s+with\b|\bis\s+is\b/si)' "$1" | perl -lpe 'print "\nPossible typos:" if $. == 1'
  grep -niE '((anonym|author|categor|custom|emphas|initial|local|minim|neutral|normal|optim|raster|real|recogn|roman|serial|standard|summar|synchron|synthes|token|optim)is(e|ing|ation|ability)|(col|behavi|hono|fav)our)' "$1" | grep -vE "\ben-GB\b" | perl -lpe 'print "\nen-GB spelling (use lang=\"en-GB\", or <!-- en-GB -->, on the same line to override):" if $. == 1'
  perl -ne '$/ = "\n\n"; print "$_" if (/\ban\s+(<[^>]*>)*(?!(L\b|http|https|href|hgroup|rb|rp|rt|rtc|li|xml|svg|svgmatrix|hour|hr|xhtml|xslt|xbl|nntp|mpeg|m[ions]|mtext|merror|h[1-6]|xmlns|xpath|s|x|sgml|huang|srgb|rsa|only|option|optgroup)\b|html)[b-df-hj-np-tv-z]/si or /\b(?<![<\/;])a\s+(?!<!--grammar-check-override-->)(<[^>]*>)*(?!&gt|one)(?:(L\b|http|https|href|hgroup|rt|rp|li|xml|svg|svgmatrix|hour|hr|xhtml|xslt|xbl|nntp|mpeg|m[ions]|mtext|merror|h[1-6]|xmlns|xpath|s|x|sgml|huang|srgb|rsa|only|option|optgroup)\b|html|[aeio])/si)' "$1" | perl -lpe 'print "\nPossible grammar problem: \"a\" instead of \"an\" or vice versa (to override, use e.g. \"a <!--grammar-check-override-->apple\"):" if $. == 1'
  grep -ni 'and/or' "$1" | perl -lpe 'print "\nOccurrences of making Ms2ger unhappy and/or annoyed:" if $. == 1'
  grep -niE '\s+$' "$1" | perl -lpe 'print "\nTrailing whitespace:" if $. == 1'
  perl -ne '$/ = "\n\n"; print "$_" if (/class="?(note|example).+(\n.+)*\s+(should|must|may|optional|recommended)(\s|$)/mi)' "$1" | perl -lpe 'print "\nRFC2119 keyword in example or note (use: might, can, has to, or override with <!--non-normative-->must):" if $. == 1'
  perl -ne '$line++; $in_domintro = 1 if (/^  <dl class="domintro">$/); print "$line: $_" if ($in_domintro && /\s+(should|must|may|optional|recommended)(\s|$)/i); $in_domintro = 0 if (/^  <\/dl>$/)' "$1" | perl -lpe 'print "\nRFC2119 keyword in domintro (use: might, can, has to, or override with <!--non-normative-->must):" if $. == 1'
  grep -ni 'class="idl"' "$1" | grep -vF '<code class="idl" data-x="">' | perl -lpe 'print "\nIrregular use of class=\"idl\":" if $. == 1'
  )

if [ -n "$MATCHES" ]; then
  echo "$MATCHES"
  exit 1
fi
