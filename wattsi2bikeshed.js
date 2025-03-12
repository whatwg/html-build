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

// Remove data-x attributes recursively.
function removeDataX(elem) {
    elem.removeAttribute(kCrossRefAttribute);
    for (const descendent of elem.querySelectorAll('[data-x]')) {
        descendent.removeAttribute(kCrossRefAttribute);
    }
}

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

// Get the "topic identifier" for cross-references like Wattsi:
// https://github.com/whatwg/wattsi/blob/b9c28036a2a174f7f87315164f001120596a95f1/src/wattsi.pas#L882-L894
function getTopicIdentifier(elem) {
    let result;
    if (elem.hasAttribute(kCrossRefAttribute)) {
        result = elem.getAttribute(kCrossRefAttribute);
    } else if (isElement(elem.firstChild) && elem.firstChild === elem.lastChild) {
        result = getTopicIdentifier(elem.firstChild);
    } else {
        result = elem.textContent;
    }
    // This matches Wattsi's MungeStringToTopic in spirit,
    // but perhaps not in every detail:
    return result
        .replaceAll('#', '')
        .replaceAll(/\s+/g, ' ')
        .toLowerCase()
        .trim();
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
        const topic = getTopicIdentifier(dfn);
        if (crossRefs.has(topic)) {
            console.warn('Duplicate <dfn> topic:', topic);
        }
        crossRefs.set(topic, dfn);

        // Remove data-x attributes. If this changes the topic, then
        // it came from data-x and is copied over to lt for Bikeshed.
        removeDataX(dfn);
        if (getTopicIdentifier(dfn) !== topic) {
            dfn.setAttribute('lt', topic);
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

        const topic = getTopicIdentifier(span);
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

        // Remove data-x attributes. This might change the topic.
        removeDataX(span);
        const needLt = getTopicIdentifier(span) !== topic;

        // Output a <a> instead of <span>.
        const a = document.createElement('a');

        for (const name of span.getAttributeNames()) {
            const value = span.getAttribute(name);
            switch (name) {
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

        if (needLt) {
            a.setAttribute('lt', topic);
        }
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

        const topic = getTopicIdentifier(code);
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

        // Remove data-x attributes. This might change the topic.
        removeDataX(code);
        const needLt = getTopicIdentifier(code) !== topic;

        const a = document.createElement('a');
        if (needLt) {
            a.setAttribute('lt', topic);
        }
        for (const name of code.getAttributeNames()) {
            a.setAttribute(name, code.getAttribute(name));
            code.removeAttribute(name);
        }
        code.replaceWith(a);
        a.appendChild(code);
    }

    for (const elem of document.querySelectorAll('[data-x]')) {
        const dataX = elem.getAttribute(kCrossRefAttribute);
        if (dataX) {
            if (elem.parentNode.localName == 'dfn') {
                // console.warn(elem.parentNode.outerHTML);
            }
            elem.setAttribute('lt', dataX);
        } else {
            // An empty data-x attribute is for when <code> or <span> shouldn't
            // link to anything, or a bare <dfn> in the output.
            switch (elem.localName) {
                case 'code':
                case 'span':
                    // Bikeshed will not change bare <code> or <span>.
                    break;
                case 'dfn':
                    // TODO: to make Bikeshed output a bare <dfn>
                    break;
                default:
                    console.warn('Empty data-x attribute:', elem.outerHTML);
            }
        }
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
