//! Postprocess step for ensuring anchor permanence: see
//! https://whatwg.org/working-mode#anchors.
//!
//! Scans for the `<script type="text/required-ids">` element, which lists
//! (whitespace-separated) IDs that must appear somewhere in the document.
//! After verifying that all listed IDs are present, removes the script element.

use crate::dom_utils::NodeHandleExt;
use html5ever::{QualName, local_name, ns};
use markup5ever_rcdom::Handle;
use std::collections::HashSet;

pub struct Processor {
    required_ids: HashSet<String>,
    script_node: Option<Handle>,
}

impl Processor {
    pub fn new() -> Self {
        Self {
            required_ids: HashSet::new(),
            script_node: None,
        }
    }

    pub fn visit(&mut self, node: &Handle) {
        // Capture and parse the <script type="text/required-ids"> element exactly once.
        if node.is_html_element(&local_name!("script")) {
            const TYPE: QualName = QualName {
                prefix: None,
                ns: ns!(),
                local: local_name!("type"),
            };
            if node.get_attribute(&TYPE).as_deref() == Some("text/required-ids") {
                assert!(
                    self.script_node.is_none(),
                    "multiple required-ids scripts encountered"
                );
                self.script_node = Some(node.clone());
                // Gather all text within the script and split on any ASCII whitespace.
                let content = node.text_content();
                for id_token in content.split_ascii_whitespace() {
                    if !id_token.is_empty() {
                        self.required_ids.insert(id_token.to_string());
                    }
                }
            }
        }

        // For elements with an id attribute, mark the ID as seen.
        if self.required_ids.is_empty() {
            return;
        }
        const ID_QN: QualName = QualName {
            prefix: None,
            ns: ns!(),
            local: local_name!("id"),
        };
        if let Some(id) = node.get_attribute(&ID_QN) {
            self.required_ids.remove(id.as_ref());
        }
    }

    pub fn apply(self) -> std::io::Result<()> {
        if !self.required_ids.is_empty() {
            let mut missing: Vec<_> = self.required_ids.into_iter().collect();
            missing.sort();
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!(
                    "Missing required IDs for anchor permanence: {}",
                    missing.join(", ")
                ),
            ));
        }

        // Remove the script element (if present) after verification.
        if let Some(script) = self.script_node {
            script.remove();
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dom_utils;
    use crate::parser::{parse_document_async, tests::serialize_for_test};
    use std::io;

    #[tokio::test]
    async fn removes_script_from_head() -> io::Result<()> {
        let parsed = parse_document_async(r#"<!DOCTYPE html>
<html><head><script type="text/required-ids">a b c</script></head><body><div id="a"></div><p id="b"></p><section id="c"></section></body></html>
"#.as_bytes()).await?;
        let document = parsed.document().clone();
        let mut processor = Processor::new();
        dom_utils::scan_dom(&document, &mut |h| processor.visit(h));
        processor.apply().unwrap();
        let serialized = serialize_for_test(&[document]);
        assert!(!serialized.contains("text/required-ids"));
        Ok(())
    }

    #[tokio::test]
    async fn no_script_present_noop() -> io::Result<()> {
        let parsed = parse_document_async(
            r#"<!DOCTYPE html>
<html><head></head><body></body></html>
"#
            .as_bytes(),
        )
        .await?;
        let document = parsed.document().clone();
        let before = serialize_for_test(&[document.clone()]);
        let mut processor = Processor::new();
        dom_utils::scan_dom(&document, &mut |h| processor.visit(h));
        processor.apply().unwrap();
        assert_eq!(before, serialize_for_test(&[document]));
        Ok(())
    }

    #[tokio::test]
    async fn whitespace_splitting() -> io::Result<()> {
        // Includes indentation, multiple spaces, and newlines in the script content.
        let parsed = parse_document_async(r#"<!DOCTYPE html><html><head><script type="text/required-ids">
        foo   bar
            baz
    qux
</script></head><body><div id="foo"></div><div id="bar"></div><div id="baz"></div><div id="qux"></div></body></html>
"#.as_bytes()).await?;
        let document = parsed.document().clone();
        let mut processor = Processor::new();
        dom_utils::scan_dom(&document, &mut |h| processor.visit(h));
        processor.apply().unwrap();
        let serialized = serialize_for_test(&[document]);
        assert!(!serialized.contains("text/required-ids"));
        Ok(())
    }

    #[tokio::test]
    async fn errors_on_missing_ids() -> io::Result<()> {
        let parsed = parse_document_async(r#"<!DOCTYPE html>
<html><head><script type="text/required-ids">foo bar baz</script></head><body><div id="foo"></div></body></html>
"#.as_bytes()).await?;
        let document = parsed.document().clone();
        let mut processor = Processor::new();
        dom_utils::scan_dom(&document, &mut |h| processor.visit(h));
        let err = processor.apply().expect_err("expected missing IDs error");
        assert!(
            err.to_string()
                .contains("Missing required IDs for anchor permanence: bar, baz")
        );
        Ok(())
    }

    #[tokio::test]
    #[should_panic(expected = "multiple required-ids scripts encountered")]
    async fn panics_on_multiple_required_ids_scripts() {
        let parsed = parse_document_async(r#"<!DOCTYPE html><html><head>
<script type="text/required-ids">a b</script>
<script type="text/required-ids">c d</script>
</head><body><div id="a"></div><div id="b"></div><div id="c"></div><div id="d"></div></body></html>"#.as_bytes()).await.unwrap();
        let document = parsed.document().clone();
        let mut processor = Processor::new();
        dom_utils::scan_dom(&document, &mut |h| processor.visit(h));
    }
}
