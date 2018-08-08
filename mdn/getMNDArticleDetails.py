#!/usr/bin/env python2
import sys
from lxml.html import parse


def normalize(string):
    return string.encode('utf-8') \
        .replace('"', '\\"') \
        .replace("\xc2\xa0", " ") \
        .replace('\n', ' ') \
        .strip()

mdnpath = sys.argv[1]
doc = parse(mdnpath)
firstParagraphXPath = '//article/p[string-length(text()) > 0][1]//text()'
title = normalize(''.join(doc.xpath('/html/head/title/text()'))
                  .split(" - ")[0].split(": ")[0])
summary = normalize(''.join(doc.xpath('//*[@class="seoSummary"]//text()')))
if summary == '':
    # Found no seoSummary, so get text of class=summary paragraph.
    summary = normalize(''.join(doc.xpath('//*[@class="summary"]//text()')))
if summary == '':
    # Found no seoSummary or summary, so get text of the first <p> of article.
    summary = normalize(''.join(doc.xpath(firstParagraphXPath)))
print '["' + mdnpath + '","' + title + '","' + summary + '"]'
