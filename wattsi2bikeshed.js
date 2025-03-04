import { JSDOM } from "jsdom";
import { readFileSync, writeFileSync } from "node:fs";

const boilerplate = `<pre class=metadata>

Group: WHATWG
H1: HTML
Shortname: html
Text Macro: TWITTER htmlstandard
Text Macro: LATESTRD 2025-01
Abstract: HTML is Bikeshed.
Indent: 1
Markup Shorthands: css off
Include MDN Panels: false
</pre>`;

function convert(infile, outfile) {
    const source = readFileSync(infile, 'utf-8');
    const dom = new JSDOM(source);
    const document = dom.window.document;

    document.body.prepend(JSDOM.fragment(boilerplate));

    document.getElementById('ref-list').remove();

    for (const elem of document.querySelectorAll('[data-x]')) {
        const value = elem.getAttribute('data-x');
        if (value) {
            if (elem.hasAttribute('lt')) {
                console.warn('Overwriting existing lt attribute:', elem.outerHTML);
            }
            elem.setAttribute('lt', value);
        } else {
            // TODO: what is an empty data-x attribute for?
            // console.warn('Empty data-x attribute:', elem.outerHTML);
        }
        elem.removeAttribute('data-x');
    }

    for (const elem of document.querySelectorAll('[data-x-href]')) {
        // TODO
        elem.removeAttribute('data-x-href');
    }

    for (const elem of document.querySelectorAll('*')) {
        for (const attrName of elem.getAttributeNames()) {
            if (!attrName.startsWith('data-')) {
                continue;
            }
            switch (attrName) {
                case 'data-lt':
                    // TODO, handle these somehow
                    break;
                case 'data-noexport':
                    // Leave alone, see comment in source.
                    break;
                default:
                    console.warn('Unhandled data attribute:', elem.outerHTML);
            }
        }
    }

    const output = document.body.innerHTML
        .replaceAll('[[', '\\[[');

    writeFileSync(outfile, output, 'utf-8');
}

convert(process.argv[2], process.argv[3]);
