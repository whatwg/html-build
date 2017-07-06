#!/usr/bin/env python
# -*- coding: utf-8 -*-

from lxml import html
import json


def strip_span(element):
    """
        Strips the span tag from any element.
        I've tried to use `strip_elements` from the lxml API but for some reason it strips everything
        inside the parent, including the text. That's why this function exists.
    """
    li = element.text_content().split()
    return (' ').join(li[1:]) if len(li) > 1 else (' ').join(li)


def form_dict(link):
    """
        Returns a dictionary created with scrapped data from a section link.
    """
    section = link.cssselect('span')
    section_text = section[0].text if section else ''
    text = strip_span(link) if section else link.text_content()

    parent_section = link.getparent().getparent().getparent()
    parent_section_title = strip_span(parent_section.cssselect('a')[0])

    if parent_section.tag == 'li':
        section_text = '{0} - {1}'.format(section_text, parent_section_title)

    return dict(
        uri=link.get('href'),
        text=text,
        section=section_text,
    )


def write_json(filename, data):
    """Writes the JSON file."""
    with open(filename, "w") as json_file:
        json_file.write(json.dumps(data))


def main():
    with open('./output/dev/index.html', 'r') as file:
        page_html = html.fromstring(file.read())
        index = page_html.cssselect('ol.toc li a')

        write_json(
            './search_index.json',
            [form_dict(link) for link in index]
        )


if __name__ == "__main__":
    main()
