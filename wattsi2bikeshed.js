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
Markup Shorthands: css off, markdown-block off
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
        .replaceAll(/[\s<>\[\\\]^{|}%]+/g, ' ').trim()
        .replaceAll(' ', '-');
}

// Get the linking text like Bikeshed:
// https://github.com/speced/bikeshed/blob/50d0ec772915adcd5cec0c2989a27fa761d70e71/bikeshed/h/dom.py#L174-L201
//
// Also approximate the additional munging Bikeshed does here:
// https://github.com/speced/bikeshed/blob/f3fd50cc3a67ecbffb562b16252237aeaa2b4eae/bikeshed/refs/manager.py#L291-L297
function getBikeshedLinkTextSet(elem) {
    const texts = new Set();

    const dataLt = elem.getAttribute('data-lt');
    if (dataLt === '') {
        return texts;
    }

    function add(lt) {
        lt = lt.trim().replaceAll(/\s+/g, ' ');
        // These are the extra bits from addLocalDfns in Bikeshed:
        lt = lt.replaceAll("’", "'");
        // TODO: line-ending em dashes or -- (if they exist in HTML)
        // TODO: only lowercase dfn types that Bikeshed would if lowercasing
        // everything results in collisions that Bikeshed doesn't have.
        lt = lt.toLowerCase();
        texts.add(lt);
    }

    if (dataLt) {
        // TODO: what's the `rawText in ["|", "||", "|||"]` condition for?
        dataLt.split('|').map(add);
    } else {
        switch (elem.localName) {
            case 'dfn':
            case 'a':
                add(elem.textContent);
                break;
            case 'h2':
            case 'h3':
            case 'h4':
            case 'h5':
            case 'h6':
                add((elem.querySelector('.content') ?? elem).textContent);
                break;
        }
    }

    const dataLocalLt = elem.getAttribute('data-local-lt');
    if (dataLocalLt) {
        if (dataLocalLt.includes('|')) {
            console.warn('Ignoring data-local-lt value containing |:', dataLocalLt);
        } else {
            add(dataLocalLt);
        }
    }

    return texts;
}

// Get the *first* linking text like Bikeshed:
// https://github.com/speced/bikeshed/blob/50d0ec772915adcd5cec0c2989a27fa761d70e71/bikeshed/h/dom.py#L215-L220
function getBikeshedLinkText(elem) {
    for (const text of getBikeshedLinkTextSet(elem)) {
        return text;
    }
    return null;
}

// Add for and lt to ensure that Bikeshed will link the <a> to the right <dfn>.
function ensureLink(a, dfn, dfnLtCounts) {
    if (dfn.hasAttribute('for')) {
        a.setAttribute('for', dfn.getAttribute('for'));
        // TODO: don't add when it's already unambiguous.
    }

    const dfnLts = getBikeshedLinkTextSet(dfn);
    if (dfnLts.size === 0) {
        console.warn('No linking text for', dfn.outerHTML);
        return;
    }
    const aLt = getBikeshedLinkText(a);
    if (!aLt) {
        console.warn('No linking text for', a.outerHTML);
        return;
    }

    if (a.hasAttribute('for')) {
        // TODO: look in dfnLts when that tracks <dfn for>
        return;
    }

    for (const lt of dfnLts) {
        if (dfnLtCounts.get(lt) === 1) {
            // This is a unique linking text.
            // Note: data-lt is rewritten to lt later. It would also work to remove
            // any data-lt attribute here and just add lt.
            a.setAttribute('data-lt', lt);
            return;
        }
    }

    if (!dfn.hasAttribute('data-local-lt')) {
        if (!dfn.id) {
            console.warn('No id for dfn', dfn.outerHTML);
            return;
        }
        // Use a prefix to make the linking text unique. The prefix is "xxx-""
        // because class="XXX" is used as a FIXME/TODO in HTML, and these
        // local-lt attributes should be removed over time.
        dfn.setAttribute('data-local-lt', `xxx-${dfn.id}`);
    }

    a.setAttribute('data-lt', dfn.getAttribute('data-local-lt'));
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

    // Handle w-nodev and similar attributes. Wattsi handling is here:
    // https://github.com/whatwg/wattsi/blob/b9c28036a2a174f7f87315164f001120596a95f1/src/wattsi.pas#L735-L759
    const includeAttributes = ['w-nodev', 'w-nosnap', 'w-noreview', 'w-nosplit'];
    const excludeAttributes = ['w-dev', 'w-nohtml'];

    const includeSelector = includeAttributes.map(attr => `[${attr}]`).join(', ');
    for (const elem of document.querySelectorAll(includeSelector)) {
        replaceWithChildren(elem);
    }
    const excludeSelector = excludeAttributes.map(attr => `[${attr}]`).join(', ');
    for (const elem of document.querySelectorAll(excludeSelector)) {
        elem.remove();
    }

    // Scan all definitions
    const crossRefs = new Map(); // map from Wattsi topic to <dfn>
    const dfnLtCounts = new Map(); // map from Bikeshed link text to number of uses in <dfn>
    for (const dfn of document.querySelectorAll('dfn')) {
        const topic = getTopic(dfn);
        if (topic === '') {
            // This isn't a linkable definition and Wattsi outputs a plain <dfn>
            // with no attributes. The closest thing in Bikeshed is a definition
            // with no linking text that is not exported.
            dfn.setAttribute('data-lt', '');
            dfn.setAttribute('noexport', '');
            continue;
        }
        if (crossRefs.has(topic)) {
            console.warn('Duplicate <dfn> topic:', topic);
        }
        crossRefs.set(topic, dfn);

        if (!dfn.hasAttribute('id')) {
            // TODO: avoid if Bikeshed would generate the same ID
            dfn.setAttribute('id', getId(topic));
        }

        const lts = getBikeshedLinkTextSet(dfn);

        // Remove "new" from the linking text of constructors.
        if (dfn.hasAttribute('constructor') && !dfn.hasAttribute('data-lt')) {
            for (const lt of lts) {
                if (lt.startsWith('new ')) {
                    dfn.setAttribute('data-lt', lt.substring(4));
                    break;
                }
            }
        }

        // Remove leading "document." from linking text of document.write/writeln.
        if (dfn.hasAttribute('method') && dfn.getAttribute('for') === 'Document' &&
            !dfn.hasAttribute('data-lt')) {
            for (const lt of lts) {
                if (lt.startsWith('document.')) {
                    dfn.setAttribute('data-lt', lt.substring(9));
                    break;
                }
            }
        }

        // Count uses of each Bikeshed linking text
        if (dfn.hasAttribute('for')) {
            // TODO: track <dfn for> as well
            continue;
        }
        for (const lt of lts) {
            const count = (dfnLtCounts.get(lt) ?? 0) + 1
            dfnLtCounts.set(lt, count);
        }
    }

    // Track used <dfn>s in order to identify the unused ones.
    const usedDfns = new Set();

    // Replace <span> with the inner <code> or a new <a>.
    // TODO: align more closely with Wattsi:
    // https://github.com/whatwg/wattsi/blob/b9c28036a2a174f7f87315164f001120596a95f1/src/wattsi.pas#L1454-L1487
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
                case 'data-lt':
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

        ensureLink(a, dfn, dfnLtCounts);
        usedDfns.add(dfn);
    }

    // Wrap <i data-x="..."> with <a>. Wattsi handling is here:
    // https://github.com/whatwg/wattsi/blob/b9c28036a2a174f7f87315164f001120596a95f1/src/wattsi.pas#L1454-L1487
    for (const i of document.querySelectorAll('i[data-x]')) {
        if (i.closest('dfn')) {
            continue;
        }

        const topic = getTopic(i);
        const dfn = crossRefs.get(topic);
        if (!dfn) {
            continue;
            // TODO: vet these cases for any that should actually be linked
            // console.log(i.outerHTML);
        }

        const a = document.createElement('a');
        i.parentNode.insertBefore(a, i);
        a.appendChild(i);

        ensureLink(a, dfn, dfnLtCounts);
        usedDfns.add(dfn);
    }

    for (const code of document.querySelectorAll('pre > code')) {
        const pre = code.parentNode;
        if (pre.firstChild !== code || pre.lastChild !== code) {
            console.warn('Skipping a <pre><code> with sibling nodes: ' + pre.outerHTML);
            continue;
        }
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
        }
        // Strip any markup in the code.
        // TODO: Indent as much as the <pre> element is indented. This is the
        // style in other WHATWG specs using Bikeshed.
        pre.textContent = '\n' + pre.textContent.trim() + '\n';
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

        ensureLink(a, dfn, dfnLtCounts);
        usedDfns.add(dfn);
    }

    // Rewrite data-lt to lt and data-local-lt to local-lt.
    for (const elem of document.querySelectorAll('[data-lt]')) {
        elem.setAttribute('lt', elem.getAttribute('data-lt'));
        elem.removeAttribute('data-lt');
    }
    for (const elem of document.querySelectorAll('[data-local-lt]')) {
        elem.setAttribute('local-lt', elem.getAttribute('data-local-lt'));
        elem.removeAttribute('data-local-lt');
    }

    for (const elem of document.querySelectorAll('[data-x]')) {
        elem.removeAttribute(kCrossRefAttribute);
    }

    for (const elem of document.querySelectorAll('[data-x-href]')) {
        // TODO
        elem.removeAttribute('data-x-href');
    }

    // Add noexport to unused <dfn>s to silence Bikeshed warnings about them.
    // TODO: vet for cases that are accidentally unused.
    for (const dfn of crossRefs.values()) {
        if (usedDfns.has(dfn)) {
            continue;
        }
        // This <dfn> is unused by Wattsi rules.
        if (dfn.hasAttribute('data-export') || dfn.hasAttribute('export')) {
            continue;
        }
        dfn.setAttribute('noexport', '');
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

    const output = document.body.innerHTML
        .replaceAll('[[', '\\[[');

    writeFileSync(outfile, output, 'utf-8');
}

convert(process.argv[2], process.argv[3]);
