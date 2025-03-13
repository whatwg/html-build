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
Complain About: accidental-2119 off, missing-example-ids off
Include MDN Panels: false
</pre>`;

const kCrossRefAttribute = 'data-x';

function replaceWithChildren(elem) {
    while (elem.firstChild) {
        elem.parentNode.insertBefore(elem.firstChild, elem);
    }
    elem.remove();
}

function isElement(node) {
    return node?.nodeType === 1;
}

function isText(node) {
    return node?.nodeType === 3;
}

const markup = /[\[\]{}<>&]/g;
function hasMarkup(text) {
    return markup.test(text);
}

// Get the "topic" for cross-references like Wattsi:
// https://github.com/whatwg/wattsi/blob/b9c28036a2a174f7f87315164f001120596a95f1/src/wattsi.pas#L882-L894
function getTopic(elem) {
    let result;
    while (true) {
        if (elem.hasAttribute(kCrossRefAttribute)) {
            result = elem.getAttribute(kCrossRefAttribute);
            break;
        } else if (isElement(elem.firstChild) && elem.firstChild === elem.lastChild) {
            elem = elem.firstChild;
            continue;
        } else {
            result = elem.textContent;
            break;
        }
    }
    // This matches Wattsi's MungeStringToTopic in spirit,
    // but perhaps not in every detail:
    return result
        .replaceAll('#', '')
        .replaceAll(/\s+/g, ' ')
        .toLowerCase()
        .trim();
}

// Convert a topic to an ID like Wattsi:
// https://github.com/whatwg/wattsi/blob/b9c28036a2a174f7f87315164f001120596a95f1/src/wattsi.pas#L786-L832
function getId(topic) {
    // Note: no toLowerCase() because this is already done in getTopic().
    return topic
        .replaceAll(/["?`]/g, '')
        .replaceAll(/[\s<>\[\\\]^{|}%]+/g, '-');
}

// Get the linking text like Bikeshed:
// https://github.com/speced/bikeshed/blob/50d0ec772915adcd5cec0c2989a27fa761d70e71/bikeshed/h/dom.py#L174-L201
function getBikeshedLinkText(elem) {
    // Note: ignoring data-lt="" and just looking at text content.
    let text;
    switch (elem.localName) {
        case 'dfn':
        case 'a':
            text = elem.textContent;
            break;
        case 'h2':
        case 'h3':
        case 'h4':
        case 'h5':
        case 'h6':
            text = (elem.querySelector('.content') ?? elem).textContent;
            break;
        default:
            return null;
    }
    return text.trim().replaceAll(/\s+/g, ' ');
}

function convert(infile, outfile) {
    const source = readFileSync(infile, 'utf-8');
    const dom = new JSDOM(source);
    const document = dom.window.document;

    document.body.prepend(JSDOM.fragment(boilerplate));

    for (const dt of document.querySelectorAll('#ref-list dt')) {
        const node = dt.firstChild;
        if (isText(node) && node.data.startsWith('[')) {
            node.data = '\\' + node.data;
        }
    }

    // TODO: handle w-* variant attributes like Wattsi does:
    // https://github.com/whatwg/wattsi/blob/b9c28036a2a174f7f87315164f001120596a95f1/src/wattsi.pas#L735-L759

    // Scan all definitions
    const crossRefs = new Map();
    for (const dfn of document.querySelectorAll('dfn')) {
        if (dfn.getAttribute(kCrossRefAttribute) === '') {
            continue;
        }
        const topic = getTopic(dfn);
        if (crossRefs.has(topic)) {
            console.warn('Duplicate <dfn> topic:', topic);
        }
        crossRefs.set(topic, dfn);

        if (!dfn.hasAttribute('id')) {
            dfn.setAttribute('id', getId(topic));
        }

        // Remove "new" from the linking text of constructors.
        if (dfn.hasAttribute('constructor')) {
            const lt = getBikeshedLinkText(dfn);
            if (lt.startsWith('new ')) {
                dfn.setAttribute('lt', lt.substring(4));
            }
        }
    }

    // Replace <span> with the inner <code> or a new <a>.
    const spans = document.querySelectorAll('span');
    for (const [i, span] of Object.entries(spans)) {
        // Don't touch any span with a descendent span.
        if (span.contains(spans[+i + 1])) {
            // TODO: vet for weird cases that need fixing
            continue;
        }
        // Leave dev/nodev alone here.
        if (span.hasAttribute('w-dev') || span.hasAttribute('w-nodev')) {
            continue;
        }
        // Leave <span> in SVG alone.
        if (span.hasAttribute('xmlns')) {
            continue;
        }

        // Empty data-x="" means it's not a link.
        if (span.getAttribute(kCrossRefAttribute) === '') {
            continue;
        }

        // An empty span with an ID is used to preserve old IDs.
        // TODO: hoist to oldids attribute for Bikeshed
        if (span.hasAttribute('id') && span.firstChild === null) {
            continue;
        }

        const topic = getTopic(span);
        const dfn = crossRefs.get(topic);
        if (!dfn) {
            // TODO: vet these cases for any that should actually be linked
            // console.log(span.outerHTML);
            continue;
        }

        if (span.hasAttribute('subdfn')) {
            // TODO: generate an ID based on the linked term, like Wattsi:
            // https://github.com/whatwg/wattsi/blob/b9c28036a2a174f7f87315164f001120596a95f1/src/wattsi.pas#L943-L961
            span.removeAttribute('subdfn');
        }

        // For <span><code>foo</code></span> and <span>"<code>SyntaxError</code>"</span>,
        // drop the outer <span> and depend on the <code> linking logic. Note that this
        // excludes the surrounding quotes from the link text, which is a minor change.
        // The <code> element is further transformed in a following step.
        function isQuote(node) {
            return false; // <- hack to disable unwrapping
            return isText(node) && node.data === '"';
        }
        const code = span.querySelector('code');
        if (code && (
            // <code> is the single child
            (span.childNodes.length === 1 && span.firstChild === code) ||
            // <code> has surrounding " text nodes
            (span.childNodes.length === 3 &&
                isQuote(span.firstChild) && isQuote(span.lastChild) &&
                span.firstChild.nextSibling === code))) {
            if (span.hasAttributes()) {
                console.warn('Discarding <span> attributes:', span.outerHTML);
            }
            replaceWithChildren(span);
            continue;
        }

        // Output a <a> instead of <span>.
        const a = document.createElement('a');

        for (const name of span.getAttributeNames()) {
            const value = span.getAttribute(name);
            switch (name) {
                case 'data-x':
                    break;
                case 'id':
                    // Copy over.
                    a.setAttribute(name, value);
                    break;
                default:
                    console.warn('Unhandled <span> attribute:', name);
            }
        }
        // Move the <span> children over to <a>.
        while (span.firstChild) {
            a.appendChild(span.firstChild);
        }
        span.replaceWith(a);
    }

    for (const code of document.querySelectorAll('pre > code')) {
        const pre = code.parentNode;
        if (code.hasAttribute('class')) {
            switch (code.className) {
                case 'idl':
                    pre.className = 'idl';
                    break;
                case 'js':
                    pre.className = 'lang-javascript';
                    break;
                case 'abnf':
                case 'css':
                case 'html':
                    case 'json':
                    pre.className = `lang-${code.className}`;
                    break;
                default:
                    console.warn('Unhandled <pre><code> class:', code.className);
            }
            code.removeAttribute('class');
        }
        if (code.getAttribute(kCrossRefAttribute) === '') {
            code.removeAttribute(kCrossRefAttribute);
        }
        if (code.hasAttributes()) {
            console.warn('Discarding <code> attributes:', code.outerHTML);
        }
        replaceWithChildren(code);
    }

    // Link <code> to the right thing.
    for (const code of document.querySelectorAll('code')) {
        // <code undefined> shouldn't be linked.
        if (code.hasAttribute('undefined')) {
            code.removeAttribute('undefined');
            continue;
        }

        // <code> inside <a> or <dfn> should be left untouched.
        if (code.closest('a, dfn')) {
            continue;
        }

        const topic = getTopic(code);
        if (topic === '') {
            continue;
        }

        const dfn = crossRefs.get(topic);
        if (!dfn) {
            console.warn('No <dfn> found for topic:', topic);
            continue;
        }

        if (code.hasAttribute('subdfn')) {
            // TODO: generate an ID based on the linked term, like Wattsi:
            // https://github.com/whatwg/wattsi/blob/b9c28036a2a174f7f87315164f001120596a95f1/src/wattsi.pas#L943-L961
            code.removeAttribute('subdfn');
        }

        const a = document.createElement('a');
        for (const name of code.getAttributeNames()) {
            a.setAttribute(name, code.getAttribute(name));
            code.removeAttribute(name);
        }
        code.replaceWith(a);
        a.appendChild(code);
    }

    for (const elem of document.querySelectorAll('[data-x]')) {
        elem.removeAttribute(kCrossRefAttribute);
    }

    for (const elem of document.querySelectorAll('[data-x-href]')) {
        // TODO
        elem.removeAttribute('data-x-href');
    }

    // Simplify <a> to Bikeshed autolinks.
    for (const a of document.querySelectorAll('a')) {
        break;
        const hasSingleTextNode = isText(a.firstChild) && a.firstChild === a.lastChild;
        if (hasSingleTextNode && !a.hasAttributes()) {
            const text = a.firstChild.data;
            if (!hasMarkup(text)) {
                a.replaceWith(`[=${text}=]`);
            }
        }
        // TODO: handle <a for>.
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
