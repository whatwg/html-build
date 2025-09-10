//! Looks at the "Optional tags" and "Void elements" sections from the HTML
//! syntax spec and replicates that information into the descriptions of the
//! individual elements.

use std::borrow::Borrow;
use std::collections::HashMap;
use std::io;

use html5ever::tendril::StrTendril;
use html5ever::{LocalName, QualName, local_name, ns};
use markup5ever_rcdom::{Handle, NodeData};
use regex::Regex;

use crate::dom_utils::{self, NodeHandleExt, heading_level};

#[derive(Default)]
struct ElementInfo {
    /// Handles on any paragraphs in the "Optional tags" section which refer to the element.
    optional_tags_info: Vec<Handle>,

    /// Whether the element appears in the "Void elements" list.
    is_void_element: bool,

    /// <dl class=element> into which this info must be added.
    dl: Option<Handle>,
}

#[derive(Default)]
pub struct Processor {
    /// The heading level of the "Optional tags" heading, if inside one.
    in_optional_tags_heading: Option<u8>,

    /// Most recently seen <dfn element>.
    most_recent_element_dfn: Option<StrTendril>,

    /// Info about elements which have been referred to in these sections.
    elements: HashMap<StrTendril, ElementInfo>,
}

impl Processor {
    pub fn new() -> Self {
        Default::default()
    }

    pub fn visit(&mut self, node: &Handle) {
        // If the heading ends the "Optional tags" section, clear that state.
        if let Some(optional_tag_heading_level) = self.in_optional_tags_heading {
            match heading_level(node) {
                Some(level) if level <= optional_tag_heading_level => {
                    self.in_optional_tags_heading = None;
                }
                _ => (),
            }
        }

        // If we encounter an "Optional tags" section, start observing relevant paragraphs.
        // When one is encountered, possibly add it.
        if let Some(level) = heading_level(node) {
            if node.text_content().trim() == "Optional tags" {
                self.in_optional_tags_heading = Some(level);
            }
        } else if self.in_optional_tags_heading.is_some() && node.is_html_element(&local_name!("p"))
        {
            self.maybe_record_optional_tags_paragraph(node);
        }

        // If we encounter the Void elements section, look for the next dt.
        if node.is_html_element(&local_name!("dfn"))
            && node.text_content().trim() == "Void elements"
            && let Some(dt) = node
                .parent_node()
                .filter(|n| n.is_html_element(&local_name!("dt")))
        {
            for dd in dom_utils::dt_descriptions(&dt) {
                dom_utils::scan_dom(&dd, &mut |n| {
                    if n.is_html_element(&local_name!("code")) {
                        let info = self.elements.entry(n.text_content()).or_default();
                        info.is_void_element = true;
                    }
                });
            }
        }

        // If we see an element dfn, watch out for the upcoming <dl class="element">.
        if node.is_html_element(&local_name!("dfn"))
            && node.has_attribute(&QualName::new(None, ns!(), LocalName::from("element")))
        {
            self.most_recent_element_dfn = Some(node.text_content());
        }

        // If we see a <dl class="element">, record that.
        if node.is_html_element(&local_name!("dl"))
            && node.has_class("element")
            && let Some(elem) = std::mem::take(&mut self.most_recent_element_dfn)
        {
            let info = self.elements.entry(elem).or_default();
            if info.dl.is_none() {
                info.dl = Some(node.clone());
            }
        }
    }

    fn maybe_record_optional_tags_paragraph(&mut self, paragraph: &Handle) {
        // The paragraph must have the structure "A(n) <code>img</code> element..."
        let children = paragraph.children.borrow();
        let mut iter = children.iter().fuse();
        match (iter.next(), iter.next(), iter.next()) {
            (Some(a), Some(b), Some(c))
                if a.node_text()
                    .is_some_and(|t| t.trim() == "A" || t.trim() == "An")
                    && b.is_html_element(&local_name!("code"))
                    && c.node_text()
                        .is_some_and(|t| t.trim().starts_with("element")) =>
            {
                let info = self.elements.entry(b.text_content()).or_default();
                info.optional_tags_info.push(paragraph.clone());
            }
            _ => (),
        }
    }

    pub fn apply(self) -> io::Result<()> {
        let data_x = LocalName::from("data-x");
        let qual_data_x = QualName::new(None, ns!(), data_x.clone());
        let dt = Handle::create_element(local_name!("dt"))
            .child(
                Handle::create_element(local_name!("span"))
                    .attribute(&data_x, "concept-element-tag-omission")
                    .text("Tag omission in text/html")
                    .build(),
            )
            .text(":")
            .build();
        let void_dd = Handle::create_element(local_name!("dd"))
            .text("No ")
            .child(
                Handle::create_element(local_name!("span"))
                    .attribute(&data_x, "syntax-end-tag")
                    .text("end tag")
                    .build(),
            )
            .text(".")
            .build();
        let default_dd = Handle::create_element(local_name!("dd"))
            .text("Neither tag is omissible.")
            .build();
        let may_re = Regex::new(r"\bmay\b").unwrap();

        for info in self.elements.into_values() {
            let dl = match info.dl {
                Some(dl) => dl,
                None => continue,
            };

            let mut to_insert = vec![dt.deep_clone()];
            if !info.optional_tags_info.is_empty() {
                // Convert <p> to <dd>, replacing "may" with "can".
                for p in info.optional_tags_info {
                    let borrowed_children = p.children.borrow();
                    let new_children = borrowed_children.iter().map(|n| {
                        let new_node = n.deep_clone();
                        dom_utils::scan_dom(&new_node, &mut |c| {
                            if let NodeData::Text { ref contents } = c.data {
                                let mut text = contents.borrow_mut();
                                *text = StrTendril::from(may_re.replace(&text, "can").borrow());
                            }
                        });
                        new_node
                    });
                    let dd = Handle::create_element(local_name!("dd"))
                        .children(new_children)
                        .build();
                    to_insert.push(dd);
                }
            } else if info.is_void_element {
                to_insert.push(void_dd.deep_clone());
            } else {
                to_insert.push(default_dd.deep_clone());
            }
            to_insert.push(Handle::create_text_node("\n"));

            let dl_children = dl.children.borrow();
            let attributes_dt = if let Some(attributes_dt) = dl_children.iter().find(|child| {
                child.is_html_element(&local_name!("dt"))
                    && child
                        .any_child(|c| c.attribute_is(&qual_data_x, "concept-element-attributes"))
            }) {
                attributes_dt.clone()
            } else {
                continue;
            };
            drop(dl_children);
            dl.insert_children_before(&attributes_dt, to_insert.into_iter());
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::{parse_document_async, tests::serialize_for_test};

    #[tokio::test]
    async fn test_simple() -> io::Result<()> {
        let parsed = parse_document_async(
            r#"
<!DOCTYPE html>
<h3>Optional tags</h3>
<p>A <code>td</code> element does very tdish things and may be very cellular.</p>
<p>An <code>audio</code> element is quite audible.</p>
<h3>Another section</h3>
<p>A <code>body</code> element is ignored because it's in another section.
<dl>
    <dt><dfn>Void elements</dfn>
    <dd><code>img</code> and <code>meta</code> are void.
    <dd><code>input</code> is too.
    <dt>Non-void elements
    <dd><code>html</code> is interesting but not void.
</dl>
<h2>Elements</h2>
<p><dfn element>audio</dfn>
<dl class=element>
<dt><span data-x=concept-element-attributes></span>
</dl>
<p><dfn element>body</dfn>
<dl class=element>
<dt><span data-x=concept-element-attributes></span>
</dl>
<p><dfn element>html</dfn>
<dl class=element>
<dt><span data-x=concept-element-attributes></span>
</dl>
<p><dfn element>img</dfn>
<dl class=element>
<dt><span data-x=concept-element-attributes></span>
</dl>
<p><dfn element>input</dfn>
<dl class=element>
<dt><span data-x=concept-element-attributes></span>
</dl>
<p><dfn element>meta</dfn>
<dl class=element>
<dt><span data-x=concept-element-attributes></span>
</dl>
<p><dfn element>td</dfn>
<dl class=element>
<dt><span data-x=concept-element-attributes></span>
</dl>
            "#
            .trim()
            .as_bytes(),
        )
        .await?;
        let document = parsed.document().clone();
        let mut proc = Processor::new();
        dom_utils::scan_dom(&document, &mut |h| proc.visit(h));
        proc.apply()?;
        assert_eq!(
            serialize_for_test(&[document]),
            r#"
<!DOCTYPE html><html><head></head><body><h3>Optional tags</h3>
<p>A <code>td</code> element does very tdish things and may be very cellular.</p>
<p>An <code>audio</code> element is quite audible.</p>
<h3>Another section</h3>
<p>A <code>body</code> element is ignored because it's in another section.
</p><dl>
    <dt><dfn>Void elements</dfn>
    </dt><dd><code>img</code> and <code>meta</code> are void.
    </dd><dd><code>input</code> is too.
    </dd><dt>Non-void elements
    </dt><dd><code>html</code> is interesting but not void.
</dd></dl>
<h2>Elements</h2>
<p><dfn element="">audio</dfn>
</p><dl class="element">
<dt><span data-x="concept-element-tag-omission">Tag omission in text/html</span>:</dt><dd>An <code>audio</code> element is quite audible.</dd>
<dt><span data-x="concept-element-attributes"></span>
</dt></dl>
<p><dfn element="">body</dfn>
</p><dl class="element">
<dt><span data-x="concept-element-tag-omission">Tag omission in text/html</span>:</dt><dd>Neither tag is omissible.</dd>
<dt><span data-x="concept-element-attributes"></span>
</dt></dl>
<p><dfn element="">html</dfn>
</p><dl class="element">
<dt><span data-x="concept-element-tag-omission">Tag omission in text/html</span>:</dt><dd>Neither tag is omissible.</dd>
<dt><span data-x="concept-element-attributes"></span>
</dt></dl>
<p><dfn element="">img</dfn>
</p><dl class="element">
<dt><span data-x="concept-element-tag-omission">Tag omission in text/html</span>:</dt><dd>No <span data-x="syntax-end-tag">end tag</span>.</dd>
<dt><span data-x="concept-element-attributes"></span>
</dt></dl>
<p><dfn element="">input</dfn>
</p><dl class="element">
<dt><span data-x="concept-element-tag-omission">Tag omission in text/html</span>:</dt><dd>No <span data-x="syntax-end-tag">end tag</span>.</dd>
<dt><span data-x="concept-element-attributes"></span>
</dt></dl>
<p><dfn element="">meta</dfn>
</p><dl class="element">
<dt><span data-x="concept-element-tag-omission">Tag omission in text/html</span>:</dt><dd>No <span data-x="syntax-end-tag">end tag</span>.</dd>
<dt><span data-x="concept-element-attributes"></span>
</dt></dl>
<p><dfn element="">td</dfn>
</p><dl class="element">
<dt><span data-x="concept-element-tag-omission">Tag omission in text/html</span>:</dt><dd>A <code>td</code> element does very tdish things and can be very cellular.</dd>
<dt><span data-x="concept-element-attributes"></span>
</dt></dl></body></html>
            "#.trim());
        Ok(())
    }
}
