//! Generates an index of WebIDL interfaces.
//! This index is inserted where "INSERT INTERFACES HERE" appears.

use std::collections::BTreeMap;
use std::io;

use html5ever::tendril::StrTendril;
use html5ever::{local_name, namespace_url, ns, QualName};
use markup5ever_rcdom::Handle;

use crate::dom_utils::NodeHandleExt;

#[derive(Default, Debug)]
struct InterfaceInfo {
    /// Number of times the interface definition was seen. Should be one.
    /// We store other numbers for convenience in error handling and reporting.
    seen: u32,

    /// The IDs of the partial interfaces, in the order they appear in the document.
    partials: Vec<StrTendril>,

    /// Set to true if a partial is missing its ID.
    has_partial_with_no_id: bool,
}

pub struct Processor {
    /// The interfaces encountered, keyed and sorted by name.
    interfaces: BTreeMap<StrTendril, InterfaceInfo>,

    /// The text nodes which contains the text "INSERT INTERFACES HERE".
    marker_nodes: Vec<Handle>,
}

/// The string which marks where the index belongs. Ideally this would be a node
/// and not plain text.
const MARKER: &str = "INSERT INTERFACES HERE";

impl Processor {
    pub fn new() -> Self {
        Processor {
            interfaces: BTreeMap::new(),
            marker_nodes: Vec::new(),
        }
    }

    pub fn visit(&mut self, node: &Handle) {
        const ID: QualName = QualName {
            prefix: None,
            ns: ns!(),
            local: local_name!("id"),
        };
        // We're looking for <code class="idl"> inside a <pre>, to find
        // potential interfaces defined there.
        //
        // One surprise here -- there is an "interface Example" that is not defined
        // according to Wattsi. It yells about this not being defined, and the
        // prior Perl preprocessing actually requires the <pre> have no
        // attributes.
        if node.is_html_element(&local_name!("code"))
            && node.has_class("idl")
            && node.parent_node().map_or(false, |p| {
                p.is_html_element(&local_name!("pre")) && !p.has_class("extract")
            })
        {
            let borrowed_children = node.children.borrow();
            for window in borrowed_children.windows(2) {
                let is_partial = match window[0].node_text() {
                    Some(a) if a.ends_with("partial interface ") => true,
                    Some(a) if a.ends_with("interface ") => false,
                    _ => continue,
                };
                // These definitions must appear as a <span>, <dfn> or <a> element.
                if !window[1].is_html_element(&local_name!("span"))
                    && !window[1].is_html_element(&local_name!("dfn"))
                    && !window[1].is_html_element(&local_name!("a"))
                {
                    continue;
                }
                let name = window[1].text_content();
                let info = self.interfaces.entry(name).or_default();
                if is_partial {
                    if let Some(id) = window[1].get_attribute(&ID) {
                        info.partials.push(id);
                    } else {
                        info.has_partial_with_no_id = true;
                    }
                } else {
                    info.seen += 1;
                }
            }
        }

        if node.node_text().map_or(false, |t| t.contains(MARKER)) {
            self.marker_nodes.push(node.clone());
        }
    }

    pub fn apply(self) -> io::Result<()> {
        // It is likely an author error to not include anywhere to insert an
        // interface index. More than one is supported, mainly because it's no
        // more work than enforcing that just one exists.
        if self.marker_nodes.is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("Marker {MARKER:?} not found."),
            ));
        }
        if self.marker_nodes.len() > 1 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "{MARKER:?} found {} times, expected just one.",
                    self.marker_nodes.len()
                ),
            ));
        }
        for marker in self.marker_nodes {
            // We need to find where the marker appears in the text so that we
            // can split it into two text nodes.
            let text = marker.node_text().expect("should still be a text node");
            let position: u32 = match text.find(MARKER) {
                None => {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!("Marker {MARKER:?} not found (but was during first pass)."),
                    ));
                }
                Some(p) => p.try_into().unwrap(),
            };
            let end_position: u32 = position + TryInto::<u32>::try_into(MARKER.len()).unwrap();
            let before = text.subtendril(0, position);
            let after = text.subtendril(end_position, text.len32() - end_position);

            // Then, we need to construct a list of interfaces and their partial interfaces.
            let mut ul =
                Handle::create_element(local_name!("ul")).attribute(&local_name!("class"), "brief");
            for (name, info) in &self.interfaces {
                if info.seen > 1 {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!("Interface {name} defined {} times.", info.seen),
                    ));
                }
                fn make_link(id: &str, text: &str) -> Handle {
                    Handle::create_element(local_name!("a"))
                        .attribute(&local_name!("href"), format!("#{id}"))
                        .text(text)
                        .build()
                }
                let mut li = Handle::create_element(local_name!("li")).child(
                    Handle::create_element(local_name!("code"))
                        .text(name.clone())
                        .build(),
                );
                match &info.partials[..] {
                    [] => (),
                    [sole_partial] => {
                        li = li.text(", ").child(make_link(sole_partial, "partial"));
                    }
                    [first, rest @ ..] => {
                        li = li.text(", ").child(make_link(first, "partial 1"));
                        for (i, p) in rest.iter().enumerate() {
                            li = li.text(" ").child(make_link(p, &(i + 2).to_string()));
                        }
                    }
                }
                ul = ul.child(li.build());
            }

            // Finally, we replace the marker's text node with the combination of the two.
            marker.replace_with(vec![
                Handle::create_text_node(before),
                ul.build(),
                Handle::create_text_node(after),
            ]);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dom_utils;
    use crate::parser::{parse_document_async, tests::serialize_for_test};

    #[tokio::test]
    async fn test_two_interfaces_in_one_block() -> io::Result<()> {
        let document = parse_document_async(
            r#"
<!DOCTYPE html>
<pre><code class=idl>
interface <dfn interface>HTMLMarqueeElement</dfn> { ... }
interface <dfn interface>HTMLBlinkElement</dfn> { ... }
</code></pre>
INSERT INTERFACES HERE
            "#
            .trim()
            .as_bytes(),
        )
        .await?;
        let mut proc = Processor::new();
        dom_utils::scan_dom(&document, &mut |h| proc.visit(h));
        proc.apply()?;
        assert_eq!(
            serialize_for_test(&[document]),
            r#"
<!DOCTYPE html><html><head></head><body><pre><code class="idl">
interface <dfn interface="">HTMLMarqueeElement</dfn> { ... }
interface <dfn interface="">HTMLBlinkElement</dfn> { ... }
</code></pre>
<ul class="brief"><li><code>HTMLBlinkElement</code></li><li><code>HTMLMarqueeElement</code></li></ul></body></html>
            "#.trim());
        Ok(())
    }

    #[tokio::test]
    async fn test_two_interfaces_in_separate_blocks() -> io::Result<()> {
        let document = parse_document_async(
            r#"
<!DOCTYPE html>
<pre><code class=idl>
interface <dfn interface>HTMLMarqueeElement</dfn> { ... }
</code></pre>
<pre><code class=idl>
interface <dfn interface>HTMLBlinkElement</dfn> { ... }
</code></pre>
INSERT INTERFACES HERE
            "#
            .trim()
            .as_bytes(),
        )
        .await?;
        let mut proc = Processor::new();
        dom_utils::scan_dom(&document, &mut |h| proc.visit(h));
        proc.apply()?;
        assert_eq!(
            serialize_for_test(&[document]),
            r#"
<!DOCTYPE html><html><head></head><body><pre><code class="idl">
interface <dfn interface="">HTMLMarqueeElement</dfn> { ... }
</code></pre>
<pre><code class="idl">
interface <dfn interface="">HTMLBlinkElement</dfn> { ... }
</code></pre>
<ul class="brief"><li><code>HTMLBlinkElement</code></li><li><code>HTMLMarqueeElement</code></li></ul></body></html>
            "#.trim());
        Ok(())
    }

    #[tokio::test]
    async fn interface_with_partial() -> io::Result<()> {
        let document = parse_document_async(
            r#"
<!DOCTYPE html>
<pre><code class=idl>
interface <dfn interface>HTMLMarqueeElement</dfn> { ... }
</code></pre>
<pre><code class=idl>
partial interface <span id=HTMLMarqueeElement-partial>HTMLMarqueeElement</span> { ... }
</code></pre>
INSERT INTERFACES HERE
            "#
            .trim()
            .as_bytes(),
        )
        .await?;
        let mut proc = Processor::new();
        dom_utils::scan_dom(&document, &mut |h| proc.visit(h));
        proc.apply()?;
        assert_eq!(
            serialize_for_test(&[document]),
            r##"
<!DOCTYPE html><html><head></head><body><pre><code class="idl">
interface <dfn interface="">HTMLMarqueeElement</dfn> { ... }
</code></pre>
<pre><code class="idl">
partial interface <span id="HTMLMarqueeElement-partial">HTMLMarqueeElement</span> { ... }
</code></pre>
<ul class="brief"><li><code>HTMLMarqueeElement</code>, <a href="#HTMLMarqueeElement-partial">partial</a></li></ul></body></html>
            "##.trim());
        Ok(())
    }

    #[tokio::test]
    async fn interface_with_two_partials() -> io::Result<()> {
        let document = parse_document_async(
            r#"
<!DOCTYPE html>
<pre><code class=idl>
interface <dfn interface>HTMLMarqueeElement</dfn> { ... }
partial interface <span id=HTMLMarqueeElement-partial>HTMLMarqueeElement</span> { ... }
partial interface <span id=HTMLMarqueeElement-partial-2>HTMLMarqueeElement</span> { ... }
</code></pre>
INSERT INTERFACES HERE
            "#
            .trim()
            .as_bytes(),
        )
        .await?;
        let mut proc = Processor::new();
        dom_utils::scan_dom(&document, &mut |h| proc.visit(h));
        proc.apply()?;
        assert_eq!(
            serialize_for_test(&[document]),
            r##"
<!DOCTYPE html><html><head></head><body><pre><code class="idl">
interface <dfn interface="">HTMLMarqueeElement</dfn> { ... }
partial interface <span id="HTMLMarqueeElement-partial">HTMLMarqueeElement</span> { ... }
partial interface <span id="HTMLMarqueeElement-partial-2">HTMLMarqueeElement</span> { ... }
</code></pre>
<ul class="brief"><li><code>HTMLMarqueeElement</code>, <a href="#HTMLMarqueeElement-partial">partial 1</a> <a href="#HTMLMarqueeElement-partial-2">2</a></li></ul></body></html>
            "##.trim());
        Ok(())
    }

    #[tokio::test]
    async fn only_partials() -> io::Result<()> {
        let document = parse_document_async(
            r#"
<!DOCTYPE html>
<pre><code class=idl>
partial interface <span id=HTMLMarqueeElement-partial>HTMLMarqueeElement</span> { ... }
partial interface <span id=HTMLMarqueeElement-partial-2>HTMLMarqueeElement</span> { ... }
</code></pre>
INSERT INTERFACES HERE
            "#
            .trim()
            .as_bytes(),
        )
        .await?;
        let mut proc = Processor::new();
        dom_utils::scan_dom(&document, &mut |h| proc.visit(h));
        proc.apply()?;
        assert_eq!(
            serialize_for_test(&[document]),
            r##"
<!DOCTYPE html><html><head></head><body><pre><code class="idl">
partial interface <span id="HTMLMarqueeElement-partial">HTMLMarqueeElement</span> { ... }
partial interface <span id="HTMLMarqueeElement-partial-2">HTMLMarqueeElement</span> { ... }
</code></pre>
<ul class="brief"><li><code>HTMLMarqueeElement</code>, <a href="#HTMLMarqueeElement-partial">partial 1</a> <a href="#HTMLMarqueeElement-partial-2">2</a></li></ul></body></html>
            "##.trim());
        Ok(())
    }

    #[tokio::test]
    async fn marker_before() -> io::Result<()> {
        let document = parse_document_async(
            r#"
<!DOCTYPE html>
INSERT INTERFACES HERE
<pre><code class=idl>
interface <dfn interface>HTMLMarqueeElement</dfn> { ... }
</code></pre>
            "#
            .trim()
            .as_bytes(),
        )
        .await?;
        let mut proc = Processor::new();
        dom_utils::scan_dom(&document, &mut |h| proc.visit(h));
        proc.apply()?;
        assert_eq!(
            serialize_for_test(&[document]),
            r#"
<!DOCTYPE html><html><head></head><body><ul class="brief"><li><code>HTMLMarqueeElement</code></li></ul>
<pre><code class="idl">
interface <dfn interface="">HTMLMarqueeElement</dfn> { ... }
</code></pre></body></html>
            "#
            .trim()
        );
        Ok(())
    }

    #[tokio::test]
    async fn no_marker() -> io::Result<()> {
        let document = parse_document_async("<!DOCTYPE html>".as_bytes()).await?;
        let mut proc = Processor::new();
        dom_utils::scan_dom(&document, &mut |h| proc.visit(h));
        let result = proc.apply();
        assert!(matches!(result, Err(e) if e.kind() == io::ErrorKind::InvalidData));
        Ok(())
    }

    #[tokio::test]
    async fn duplicate_marker() -> io::Result<()> {
        let document = parse_document_async(
            "<!DOCTYPE html><div>INSERT INTERFACES HERE</div><div>INSERT INTERFACES HERE</div>"
                .as_bytes(),
        )
        .await?;
        let mut proc = Processor::new();
        dom_utils::scan_dom(&document, &mut |h| proc.visit(h));
        let result = proc.apply();
        assert!(matches!(result, Err(e) if e.kind() == io::ErrorKind::InvalidData));
        Ok(())
    }

    #[tokio::test]
    async fn duplicate_dfn() -> io::Result<()> {
        let document = parse_document_async(
            r#"
<!DOCTYPE html>
<pre><code class=idl>
interface <dfn interface>HTMLMarqueeElement</dfn> { ... }
interface <dfn interface>HTMLMarqueeElement</dfn> { ... }
</code></pre>
            "#
            .as_bytes(),
        )
        .await?;
        let mut proc = Processor::new();
        dom_utils::scan_dom(&document, &mut |h| proc.visit(h));
        let result = proc.apply();
        assert!(matches!(result, Err(e) if e.kind() == io::ErrorKind::InvalidData));
        Ok(())
    }
}
