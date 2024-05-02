//! Replaces <!--REPRESENTS tagname--> comments with the HTML which appears in a
//! paragraph of the form:
//!   <p>The <code>tagname</code> element <span>represents</span> ...</p>

use std::collections::HashMap;
use std::io;
use std::rc::Rc;

use crate::dom_utils::NodeHandleExt;
use html5ever::local_name;
use html5ever::tendril::StrTendril;
use markup5ever_rcdom::{Handle, NodeData};

pub struct Processor {
    /// Map from tag name (as found in the paragraph) to the <span> which
    /// contains the text "represents".
    represents: HashMap<StrTendril, Handle>,

    /// List of <!--REPRESENTS--> comments to be replaced, and what tag name
    /// they correspond to.
    placeholders: Vec<(Handle, StrTendril)>,
}

/// Walks from the text node "represents" and finds the tag name and the
/// span that marks where the description begins, or returns None if that
/// cannot be found.
fn find_tag_name(represents_text: &Handle) -> Option<(StrTendril, Handle)> {
    let span = represents_text
        .parent_node()
        .filter(|p| p.is_html_element(&local_name!("span")))?;
    let p = span
        .parent_node()
        .filter(|p| p.is_html_element(&local_name!("p")))?;
    let children = p.children.borrow();
    match &children[..] {
        [a, b, c, d, ..]
            if a.node_text().as_deref().map(|x| x.trim()) == Some("The")
                && b.is_html_element(&local_name!("code"))
                && c.node_text().as_deref().map(|x| x.trim()) == Some("element")
                && Rc::ptr_eq(d, &span) =>
        {
            Some((b.text_content(), span))
        }
        _ => None,
    }
}

impl Processor {
    pub fn new() -> Self {
        Self {
            represents: HashMap::new(),
            placeholders: Vec::new(),
        }
    }

    /// Should be called for each node the document. Records when it sees a
    /// <span>represents</span> and which element it is defining
    pub fn visit(&mut self, node: &Handle) {
        match node.data {
            NodeData::Text { ref contents } if contents.borrow().as_ref() == "represents" => {
                if let Some((tag, span)) = find_tag_name(node) {
                    self.represents.insert(tag, span);
                }
            }
            NodeData::Comment { ref contents } if contents.starts_with("REPRESENTS ") => {
                self.placeholders
                    .push((node.clone(), contents.subtendril(11, contents.len32() - 11)));
            }
            _ => (),
        }
    }

    pub fn apply(self) -> io::Result<()> {
        for (placeholder, ref tag) in self.placeholders {
            let span = match self.represents.get(tag) {
                Some(span) => span,
                None => {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!("<!--REPRESENTS {}--> refers to unknown tag", tag),
                    ));
                }
            };
            let parent = match span.parent_node() {
                Some(p) => p,
                None => continue,
            };
            let replacements = parent
                .children
                .borrow()
                .iter()
                .skip_while(|s| !Rc::ptr_eq(s, span))
                .skip(1)
                .enumerate()
                .map(|(index, sibling)| {
                    let clone = sibling.deep_clone();
                    // Capitalize the first letter of the first node (which is expected to be text).
                    if let (0, NodeData::Text { ref contents }) = (index, &clone.data) {
                        contents.replace_with(|text| capitalize(text.trim_start()));
                    }
                    clone
                })
                .collect();
            placeholder.replace_with(replacements);
        }
        Ok(())
    }
}

fn capitalize(text: &str) -> StrTendril {
    let mut chars = text.chars();
    match chars.next() {
        Some(c) => {
            let mut capitalized = StrTendril::from_char(c.to_ascii_uppercase());
            capitalized.push_slice(chars.as_str());
            capitalized
        }
        None => StrTendril::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dom_utils;
    use crate::parser::{parse_document_async, tests::serialize_for_test};

    #[tokio::test]
    async fn test_represents() -> io::Result<()> {
        // Uses can occur either before or after.
        let document = parse_document_async("<!DOCTYPE html><p><!--REPRESENTS chair--><p>The <code>chair</code> element <span>represents</span> a seat\nat a <code>table</code>.<p><!--REPRESENTS chair-->".as_bytes()).await?;
        let mut proc = Processor::new();
        dom_utils::scan_dom(&document, &mut |h| proc.visit(h));
        proc.apply()?;
        assert_eq!(
            serialize_for_test(&[document]),
            "<!DOCTYPE html><html><head></head><body><p>A seat\nat a <code>table</code>.</p><p>The <code>chair</code> element <span>represents</span> a seat\nat a <code>table</code>.</p><p>A seat\nat a <code>table</code>.</p></body></html>"
        );
        Ok(())
    }

    #[tokio::test]
    async fn test_represents_undefined() -> io::Result<()> {
        // Uses can occur either before or after.
        let document = parse_document_async("<!DOCTYPE html><p><!--REPRESENTS chain--><p>The <code>chair</code> element <span>represents</span> a seat\nat a <code>table</code>.<p><!--REPRESENTS chair-->".as_bytes()).await?;
        let mut proc = Processor::new();
        dom_utils::scan_dom(&document, &mut |h| proc.visit(h));
        let result = proc.apply();
        assert!(matches!(result, Err(e) if e.kind() == io::ErrorKind::InvalidData));
        Ok(())
    }
}
