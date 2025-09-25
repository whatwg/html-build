//! Converts custom attributes `algorithm=""` and `var-scope=""` to `data-`
//! equivalents, to preserve validity of the output document. Errors on `<var>`s
//! outside of those scopes, unless the `<var>` has an `ignore=""` attribute.
//
// TODO: check for `<var>`s inside of these scopes that are only used once, and
// error when such lone `<var>`s are encountered.

use std::fmt::Write as _;
use std::io;

use html5ever::Attribute;
use html5ever::{LocalName, QualName, local_name, ns};
use markup5ever_rcdom::{Handle, NodeData};

use crate::dom_utils::NodeHandleExt;
use crate::rcdom_with_line_numbers::RcDomWithLineNumbers;

pub struct Processor<'a> {
    // Parser context (for line numbers)
    parsed: &'a RcDomWithLineNumbers,

    // Rename targets: elements that start a variable scope whose attributes we will rewrite
    scope_roots: Vec<Handle>,

    // Offenses collected during visit (reported in apply())
    disallowed_data_algorithm: Vec<Handle>,
    disallowed_data_var_scope: Vec<Handle>,
    both_old_attrs: Vec<Handle>,
    var_out_of_scope_msgs: Vec<String>,

    // Preorder traversal state
    stack: Vec<Handle>,
    scope_flags: Vec<bool>,
    scope_depth: usize,
    domintro_flags: Vec<bool>,
    domintro_depth: usize,

    // Edits to perform during apply()
    vars_to_strip_ignore: Vec<Handle>,
}

impl<'a> Processor<'a> {
    pub fn new(parsed: &'a RcDomWithLineNumbers) -> Self {
        Self {
            parsed,
            scope_roots: vec![],
            disallowed_data_algorithm: vec![],
            disallowed_data_var_scope: vec![],
            both_old_attrs: vec![],
            var_out_of_scope_msgs: vec![],
            stack: vec![],
            scope_flags: vec![],
            scope_depth: 0,
            domintro_flags: vec![],
            domintro_depth: 0,
            vars_to_strip_ignore: vec![],
        }
    }

    pub fn visit(&mut self, node: &Handle) {
        if !node.is_element() {
            return;
        }

        let old_algorithm = QualName::new(None, ns!(), LocalName::from("algorithm"));
        let old_var_scope = QualName::new(None, ns!(), LocalName::from("var-scope"));
        let data_algorithm = QualName::new(None, ns!(), LocalName::from("data-algorithm"));
        let data_var_scope = QualName::new(None, ns!(), LocalName::from("data-var-scope"));
        let ignore_attr = QualName::new(None, ns!(), LocalName::from("ignore"));

        // Maintain stack based on preorder and parent link
        let parent = node.parent_node();
        while let Some(top) = self.stack.last() {
            let is_parent = match &parent {
                Some(p) => std::rc::Rc::ptr_eq(top, p),
                None => false,
            };
            if is_parent {
                break;
            }
            self.stack.pop();
            if self.scope_flags.pop().unwrap_or(false) {
                self.scope_depth -= 1;
            }
            if self.domintro_flags.pop().unwrap_or(false) {
                self.domintro_depth -= 1;
            }
        }

        let starts_scope = node.has_attribute(&old_algorithm) || node.has_attribute(&old_var_scope);
        if starts_scope {
            self.scope_depth += 1;
        }
        let starts_domintro = node.has_class("domintro");
        if starts_domintro {
            self.domintro_depth += 1;
        }
        self.stack.push(node.clone());
        self.scope_flags.push(starts_scope);
        self.domintro_flags.push(starts_domintro);

        if starts_scope {
            self.scope_roots.push(node.clone());
        }

        if node.has_attribute(&data_algorithm) {
            self.disallowed_data_algorithm.push(node.clone());
        }
        if node.has_attribute(&data_var_scope) {
            self.disallowed_data_var_scope.push(node.clone());
        }
        if node.has_attribute(&old_algorithm) && node.has_attribute(&old_var_scope) {
            self.both_old_attrs.push(node.clone());
        }

        // Check <var> semantics
        if node.is_html_element(&local_name!("var")) {
            if node.has_attribute(&ignore_attr) {
                // Ignore `<var>` with `ignore=""` attribute, and note it for later removal.
                self.vars_to_strip_ignore.push(node.clone());
            } else if self.domintro_depth > 0 {
                // Ignore `<var>` inside domintro sections.
            } else if self.scope_depth == 0 {
                let text = node.text_content();
                let mut msg = String::new();
                if let Some(n) = self.parsed.line_number_for(node) {
                    let _ = write!(msg, "Line {}: ", n);
                }
                let _ = write!(
                    msg,
                    "\"{}\" <var> outside algorithm=\"\"/var-scope=\"\" container.",
                    text.trim()
                );
                self.var_out_of_scope_msgs.push(msg);
            }
        }
    }

    pub fn apply(self) -> io::Result<()> {
        if !self.disallowed_data_algorithm.is_empty() || !self.disallowed_data_var_scope.is_empty()
        {
            let mut msgs = Vec::new();
            for n in self.disallowed_data_algorithm {
                let line = self
                    .parsed
                    .line_number_for(&n)
                    .map(|ln| format!("Line {}: ", ln))
                    .unwrap_or_default();
                msgs.push(format!(
                    "{}data-algorithm=\"\" present in source. Use algorithm=\"\" instead.",
                    line
                ));
            }
            for n in self.disallowed_data_var_scope {
                let line = self
                    .parsed
                    .line_number_for(&n)
                    .map(|ln| format!("Line {}: ", ln))
                    .unwrap_or_default();
                msgs.push(format!(
                    "{}data-var-scope=\"\" present in source. Use var-scope=\"\" instead.",
                    line
                ));
            }
            return Err(io::Error::new(io::ErrorKind::InvalidData, msgs.join("\n")));
        }
        if !self.both_old_attrs.is_empty() {
            let mut msgs = Vec::new();
            for n in self.both_old_attrs {
                let line = self
                    .parsed
                    .line_number_for(&n)
                    .map(|ln| format!("Line {}: ", ln))
                    .unwrap_or_default();
                msgs.push(format!(
                    "{}both algorithm=\"\" and var-scope=\"\" present on the same element. Pick one.",
                    line
                ));
            }
            return Err(io::Error::new(io::ErrorKind::InvalidData, msgs.join("\n")));
        }

        if !self.var_out_of_scope_msgs.is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                self.var_out_of_scope_msgs.join("\n"),
            ));
        }

        let old_algorithm = QualName::new(None, ns!(), LocalName::from("algorithm"));
        let new_algorithm = QualName::new(None, ns!(), LocalName::from("data-algorithm"));
        let old_var_scope = QualName::new(None, ns!(), LocalName::from("var-scope"));
        let new_var_scope = QualName::new(None, ns!(), LocalName::from("data-var-scope"));
        let ignore_attr = QualName::new(None, ns!(), LocalName::from("ignore"));

        for node in self.scope_roots {
            if let NodeData::Element { ref attrs, .. } = node.data {
                let mut attrs = attrs.borrow_mut();
                rename_if_present(&mut attrs, &old_algorithm, &new_algorithm)?;
                rename_if_present(&mut attrs, &old_var_scope, &new_var_scope)?;
            }
        }
        for var_node in self.vars_to_strip_ignore {
            var_node.remove_attribute(&ignore_attr);
        }
        Ok(())
    }
}

fn rename_if_present(
    attrs: &mut Vec<Attribute>,
    old_name: &QualName,
    new_name: &QualName,
) -> io::Result<()> {
    if let Some((idx, value)) = attrs
        .iter()
        .enumerate()
        .find_map(|(i, a)| (a.name == *old_name).then(|| (i, a.value.clone())))
    {
        attrs.remove(idx);
        attrs.push(Attribute {
            name: new_name.clone(),
            value,
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dom_utils;
    use crate::parser::{parse_document_async, tests::serialize_for_test};

    #[tokio::test]
    async fn test_basic_conversion() {
        let parsed = parse_document_async(
            r##"<!DOCTYPE html>
<div algorithm></div>
<p algorithm="foo">Hi</p>
<span var-scope="bar"></span>
<em>No change</em>
"##
            .as_bytes(),
        )
        .await
        .unwrap();
        let document = parsed.document().clone();

        let mut proc = Processor::new(&parsed);
        dom_utils::scan_dom(&document, &mut |h| proc.visit(h));
        proc.apply().unwrap();

        assert_eq!(
            serialize_for_test(&[document]),
            r##"<!DOCTYPE html><html><head></head><body><div data-algorithm=""></div>
<p data-algorithm="foo">Hi</p>
<span data-var-scope="bar"></span>
<em>No change</em>
</body></html>"##
        );
    }

    #[tokio::test]
    async fn test_error_on_existing_data_attr() {
        let parsed = parse_document_async(
            r##"<!DOCTYPE html>
<div data-algorithm></div>
<div data-var-scope></div>
"##
            .as_bytes(),
        )
        .await
        .unwrap();
        let document = parsed.document().clone();

        let mut proc = Processor::new(&parsed);
        dom_utils::scan_dom(&document, &mut |h| proc.visit(h));
        let result = proc.apply();
        let err = result.unwrap_err();
        assert!(err.to_string().contains("Line 2: "));
        assert!(err.to_string().contains("Line 3: "));
    }

    #[tokio::test]
    async fn test_error_on_both() {
        let parsed = parse_document_async(
            r##"<!DOCTYPE html>
<div algorithm="a" var-scope="b"></div>
"##
            .as_bytes(),
        )
        .await
        .unwrap();
        let document = parsed.document().clone();

        let mut proc = Processor::new(&parsed);
        dom_utils::scan_dom(&document, &mut |h| proc.visit(h));
        let result = proc.apply();
        let err = result.unwrap_err();
        assert!(err.to_string().contains("Line 2: "));
    }

    #[tokio::test]
    async fn test_var_ignore_removes_attr_and_no_error() {
        let parsed = parse_document_async(
            r##"<!DOCTYPE html>
<p>Outside scope <var ignore>foo</var></p>
"##
            .as_bytes(),
        )
        .await
        .unwrap();
        let document = parsed.document().clone();

        let mut proc = Processor::new(&parsed);
        dom_utils::scan_dom(&document, &mut |h| proc.visit(h));
        // Should not error because var has ignore
        proc.apply().unwrap();

        assert_eq!(
            serialize_for_test(&[document]),
            r##"<!DOCTYPE html><html><head></head><body><p>Outside scope <var>foo</var></p>
</body></html>"##
        );
    }

    #[tokio::test]
    async fn test_var_outside_scope_errors() {
        let parsed = parse_document_async(
            r##"<!DOCTYPE html>
    <p>Outside scope <var>bar</var></p>
    "##
            .as_bytes(),
        )
        .await
        .unwrap();
        let document = parsed.document().clone();

        let mut proc = Processor::new(&parsed);
        dom_utils::scan_dom(&document, &mut |h| proc.visit(h));
        let result = proc.apply();
        let err = result.unwrap_err();
        assert!(err.to_string().contains("Line 2: "));
    }

    #[tokio::test]
    async fn test_var_inside_algorithm_ok() {
        let parsed = parse_document_async(
            r##"<!DOCTYPE html>
<div algorithm="algorithm label"><p>In scope <var>n</var></p></div>
"##
            .as_bytes(),
        )
        .await
        .unwrap();
        let document = parsed.document().clone();

        let mut proc = Processor::new(&parsed);
        dom_utils::scan_dom(&document, &mut |h| proc.visit(h));
        proc.apply().unwrap();

        assert_eq!(
            serialize_for_test(&[document]),
            r##"<!DOCTYPE html><html><head></head><body><div data-algorithm="algorithm label"><p>In scope <var>n</var></p></div>
</body></html>"##
        );
    }

    #[tokio::test]
    async fn test_var_inside_var_scope_ok() {
        let parsed = parse_document_async(
            r##"<!DOCTYPE html>
<section var-scope="scope label"><p>In scope <var>x</var></p></section>
"##
            .as_bytes(),
        )
        .await
        .unwrap();
        let document = parsed.document().clone();

        let mut proc = Processor::new(&parsed);
        dom_utils::scan_dom(&document, &mut |h| proc.visit(h));
        proc.apply().unwrap();

        assert_eq!(
            serialize_for_test(&[document]),
            r##"<!DOCTYPE html><html><head></head><body><section data-var-scope="scope label"><p>In scope <var>x</var></p></section>
</body></html>"##
        );
    }

    #[tokio::test]
    async fn test_var_inside_domintro_ok() {
        let parsed = parse_document_async(
            r##"<!DOCTYPE html>
  <dl class="domintro">
   <dt><code data-x=""><var>variable</var> = <var>object</var>.<span data-x="x-that">method</span>([<var>optionalArgument</var>])</code></dt>

   <dd><p>This is a note to authors describing the usage of an interface.</p></dd>
  </dl>
"##
            .as_bytes()
        ).await.unwrap();
        let document = parsed.document().clone();
        let mut proc = Processor::new(&parsed);
        dom_utils::scan_dom(&document, &mut |h| proc.visit(h));
        // No scope present, but domintro should suppress the error.
        proc.apply().unwrap();

        assert_eq!(
            serialize_for_test(&[document]),
            r##"<!DOCTYPE html><html><head></head><body><dl class="domintro">
   <dt><code data-x=""><var>variable</var> = <var>object</var>.<span data-x="x-that">method</span>([<var>optionalArgument</var>])</code></dt>

   <dd><p>This is a note to authors describing the usage of an interface.</p></dd>
  </dl>
</body></html>"##
        );
    }
}
