URL_REGEX=\s+<td>(?:<bdi>)?<a.*href=".+html.spec.whatwg.org[^\#]+\#([^"]*).+
PSEUDO_CLASSES=active checked default defined disabled enabled focus hover\
	       in-range indeterminate invalid link dir optional out-of-range\
	       read-only read-write required target valid visited
PERL=perl
GREP=grep
WGET=wget
RG=rg
JQ=jq

id-map.json: .id-list
	(echo "{"; COMMA=""; for ID in $$(cat .id-list); \
	  do echo "$$COMMA\"$$ID\": [" ; COMMA=","; ARRAY_COMMA=""; \
	  for article in \
	  $$($(RG) -l "\s+<td>(?:<bdi>)?<a.*href=\".+html.spec.whatwg.org[^#]+#$$ID\"" \
	    developer.mozilla.org/en-US/docs/Web | sort); do \
	    articledata=$$(./getMNDArticleDetails.py $$article); \
	    echo "$$ARRAY_COMMA$$articledata"; ARRAY_COMMA=","; done; \
	    echo "]"; done; echo "}") \
	  | $(PERL) -pe 's/\.html"/"/' \
	  | $(PERL) -pe 's/developer\.mozilla\.org\/en-US\/docs\/Web\///' \
	  | $(PERL) -pe 's/\x{5c}\x{28}/\(/g' \
	  | $(PERL) -pe 's/\x{5c}\x{29}/\)/g' \
	  | $(PERL) -pe 's/\x{5c}\x{2a}/\*/g' \
	  | $(JQ) . > $@

.id-list: developer.mozilla.org
	$(RG) -t html --no-filename '$(URL_REGEX)' $< \
	  | $(PERL) -pe 's/$(URL_REGEX)/$$1/' | sort  | uniq \
	  | $(PERL) -pe 's/\(/\\(/g' \
	  | $(PERL) -pe 's/\)/\\)/g' \
	  | $(PERL) -pe 's/\*/\\*/g' \
	  | sort  | uniq > $@
	# Fail if the ID list contains any generated "back" IDs.
	# (These need to be changed in the corresponding MDN article to
	# some other non-back-IDs.)
	! ($(GREP) -v "the-lang-and-xml:lang-attributes" $@ \
	  | $(GREP) "\w:\w")

developer.mozilla.org:
	-$(WGET) --mirror --adjust-extension --trust-server-names \
	  --include-directories=/en-US/docs/Web/HTML,/en-US/docs/Web/API \
	  --exclude-directories='\
/en-US/docs/Archive,\
/en-US/docs/Mozilla,\
/en-US/docs/Web/API/Bluetooth*,\
/en-US/docs/Web/API/Device*,\
/en-US/docs/Web/API/EXT*,\
/en-US/docs/Web/API/Gamepad*,\
/en-US/docs/Web/API/IDB*,\
/en-US/docs/Web/API/MediaKey*,\
/en-US/docs/Web/API/MediaStream*,\
/en-US/docs/Web/API/MediaTrack*,\
/en-US/docs/Web/API/OES*,\
/en-US/docs/Web/API/Payment*,\
/en-US/docs/Web/API/Performance*,\
/en-US/docs/Web/API/Presentation*,\
/en-US/docs/Web/API/RTC*,\
/en-US/docs/Web/API/Readable*,\
/en-US/docs/Web/API/SVG*,\
/en-US/docs/Web/API/ServiceWorker*,\
/en-US/docs/Web/API/Speech*,\
/en-US/docs/Web/API/WebVR*,\
/en-US/docs/Web/API/VR*,\
/en-US/docs/Web/API/WEBGL*,\
/en-US/docs/Web/API/WebGL*' \
	  --reject '*$$edit,*$$history,*$$json,*$$locales,\
*Bluetooth*,\
*Device*,\
*EXT*,\
*Gamepad*,\
*IDB*,\
*MediaKey*,\
*MediaStream*,\
*MediaTrack*,\
*Moz*,\
*Ms*,\
*OES*,\
*Performance*,\
*Presentation*,\
*RTC*,\
*Readable*,\
*SVG*,\
*ServiceWorker*,\
*Speech*,\
*VR*,\
*WEBGL*,\
*WebGL*' \
	  https://developer.mozilla.org/en-US/docs/Web
	mkdir $@/en-US/docs/Web/CSS
	for PSEUDO_CLASS in $(PSEUDO_CLASSES); do \
	  $(WGET) --adjust-extension \
	  https://developer.mozilla.org/en-US/docs/Web/CSS/:$$PSEUDO_CLASS; \
	  mv :$$PSEUDO_CLASS.html $@/en-US/docs/Web/CSS/; \
	done
	$(WGET) --adjust-extension \
	  https://developer.mozilla.org/en-US/docs/Web/CSS/Pseudo-classes
	mv Pseudo-classes.html $@/en-US/docs/Web/CSS/

clean:
	rm -f .id-list
	rm -rf developer.mozilla.org
