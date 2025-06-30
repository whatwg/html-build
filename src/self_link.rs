//! Inserts `<a class="self-link" href="#ID">` links for elements with `id` attributes and certain classes.

use html5ever::tendril::StrTendril;
use html5ever::{QualName, local_name, namespace_url, ns};
use markup5ever_rcdom::Handle;
use url::Url;

use crate::dom_utils::NodeHandleExt;

const TARGET_CLASSES: &[&str] = &["example", "note", "XXX"];

enum Edit {
    InsertAsFirstChild(Handle, StrTendril),
    InsertAfterSummary(Handle, StrTendril),
}

pub struct Processor {
    edits: Vec<Edit>,
}

impl Processor {
    pub fn new() -> Self {
        Self { edits: vec![] }
    }

    pub fn visit(&mut self, node: &Handle) {
        if !node.is_element() {
            return;
        }

        if !node.has_any_class(TARGET_CLASSES) {
            return;
        }

        if node.any_child(|c| c.has_class("self-link")) {
            return;
        }

        if let Some(id) = node.get_attribute(&QualName::new(None, ns!(), local_name!("id"))) {
            if node.is_html_element(&local_name!("details")) {
                self.edits.push(Edit::InsertAfterSummary(node.clone(), id));
            } else {
                self.edits.push(Edit::InsertAsFirstChild(node.clone(), id));
            }
        }
    }

    pub fn apply(self) -> std::io::Result<()> {
        for edit in self.edits {
            match edit {
                Edit::InsertAsFirstChild(node, id) => {
                    let link = create_self_link(&id);
                    node.prepend_child(link);
                }
                Edit::InsertAfterSummary(node, id) => {
                    let link = create_self_link(&id);
                    let summary = node
                        .children
                        .borrow()
                        .iter()
                        .find(|c| c.is_html_element(&local_name!("summary")))
                        .cloned();

                    if let Some(summary) = summary {
                        let mut children = node.children.borrow_mut();
                        let summary_pos = children
                            .iter()
                            .position(|c| std::rc::Rc::ptr_eq(c, &summary))
                            .unwrap();
                        children.insert(summary_pos + 1, link);
                    } else {
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::InvalidData,
                            "details element with self-link target class has no summary",
                        ));
                    }
                }
            }
        }
        Ok(())
    }
}

fn create_self_link(id: &str) -> Handle {
    let mut url = Url::parse("https://html.spec.whatwg.org/multipage/").unwrap();
    url.set_fragment(Some(id));
    let href = url.fragment().unwrap_or("");

    Handle::create_element(local_name!("a"))
        .attribute(&local_name!("href"), format!("#{}", href))
        .attribute(&local_name!("class"), "self-link")
        .build()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dom_utils;
    use crate::parser::{parse_document_async, tests::serialize_for_test};

    #[tokio::test]
    async fn test_add_self_link() {
        let document = parse_document_async(
            r##"<!DOCTYPE html>
<div class="example" id="foo"></div>
<div class="note" id="bar"></div>
<div class="XXX" id="baz"></div>
<div class="example"></div>
<div id="qux"></div>
"##
            .as_bytes(),
        )
        .await
        .unwrap();

        let mut processor = Processor::new();
        dom_utils::scan_dom(&document, &mut |h| processor.visit(h));
        processor.apply().unwrap();

        assert_eq!(
            serialize_for_test(&[document]),
            r##"<!DOCTYPE html><html><head></head><body><div class="example" id="foo"><a href="#foo" class="self-link"></a></div>
<div class="note" id="bar"><a href="#bar" class="self-link"></a></div>
<div class="XXX" id="baz"><a href="#baz" class="self-link"></a></div>
<div class="example"></div>
<div id="qux"></div>
</body></html>"##
        );
    }

    #[tokio::test]
    async fn test_add_self_link_details() {
        let document = parse_document_async(
            r##"<!DOCTYPE html>
<details class="example" id="foo"><summary>Foo</summary></details>
"##
            .as_bytes(),
        )
        .await
        .unwrap();

        let mut processor = Processor::new();
        dom_utils::scan_dom(&document, &mut |h| processor.visit(h));
        processor.apply().unwrap();

        assert_eq!(
            serialize_for_test(&[document]),
            r##"<!DOCTYPE html><html><head></head><body><details class="example" id="foo"><summary>Foo</summary><a href="#foo" class="self-link"></a></details>
</body></html>"##
        );
    }

    #[tokio::test]
    async fn test_add_self_link_details_no_summary() {
        let document = parse_document_async(
            r##"<!DOCTYPE html><details class="example" id="foo"></details>"##.as_bytes(),
        )
        .await
        .unwrap();

        let mut processor = Processor::new();
        dom_utils::scan_dom(&document, &mut |h| processor.visit(h));
        let result = processor.apply();
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn test_add_self_link_already_present() {
        let document = parse_document_async(
            r##"<!DOCTYPE html>
<div class="example" id="foo"><a class="self-link" href="#foo"></a></div>
"##
            .as_bytes(),
        )
        .await
        .unwrap();

        let mut processor = Processor::new();
        dom_utils::scan_dom(&document, &mut |h| processor.visit(h));
        processor.apply().unwrap();

        assert_eq!(
            serialize_for_test(&[document]),
            r##"<!DOCTYPE html><html><head></head><body><div class="example" id="foo"><a class="self-link" href="#foo"></a></div>
</body></html>"##
        );
    }

    #[tokio::test]
    async fn test_url_encoding() {
        let document = parse_document_async(
            r##"<!DOCTYPE html>
<div class="example" id="foo bar"></div>
"##
            .as_bytes(),
        )
        .await
        .unwrap();

        let mut processor = Processor::new();
        dom_utils::scan_dom(&document, &mut |h| processor.visit(h));
        processor.apply().unwrap();

        assert_eq!(
            serialize_for_test(&[document]),
            r##"<!DOCTYPE html><html><head></head><body><div class="example" id="foo bar"><a href="#foo%20bar" class="self-link"></a></div>
</body></html>"##
        );
    }
}
