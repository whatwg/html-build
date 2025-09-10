// This provides a wrapper around RcDom which tracks line numbers in the errors.

use delegate::delegate;
use html5ever::interface::TreeSink;
use html5ever::{
    Attribute, ExpandedName, QualName,
    tendril::StrTendril,
    tree_builder::{ElementFlags, NodeOrText, QuirksMode},
};
use markup5ever_rcdom::{Handle, Node, RcDom};
use std::borrow::Cow;
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::io;
use std::rc::Rc;

pub struct RcDomWithLineNumbers {
    dom: RcDom,
    current_line: Cell<u64>,
    node_line_map: RefCell<HashMap<*const Node, u64>>,
}

#[cfg(test)]
impl std::fmt::Debug for RcDomWithLineNumbers {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("RcDomWithLineNumbers")
    }
}

impl RcDomWithLineNumbers {
    // Expose out the document and errors from the inner RcDom
    pub fn document(&self) -> &Handle {
        &self.dom.document
    }

    pub fn create_error_from_parse_errors(&self) -> io::Result<()> {
        if !self.dom.errors.borrow().is_empty() {
            let error_messages = self
                .dom
                .errors
                .borrow()
                .iter()
                .map(|e| e.to_string())
                .collect::<Vec<String>>()
                .join("\n");
            Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("Parse errors encountered:\n\n{error_messages}"),
            ))
        } else {
            Ok(())
        }
    }

    /// Returns the 1-based line number where the element represented by `handle`
    /// was created, if known.
    pub fn line_number_for(&self, handle: &Handle) -> Option<u64> {
        let key = Rc::as_ptr(handle);
        self.node_line_map.borrow().get(&key).cloned()
    }
}

impl Default for RcDomWithLineNumbers {
    fn default() -> Self {
        Self {
            dom: RcDom::default(),
            current_line: Cell::new(1),
            node_line_map: RefCell::new(HashMap::new()),
        }
    }
}

impl TreeSink for RcDomWithLineNumbers {
    type Output = RcDomWithLineNumbers;
    type Handle = <RcDom as TreeSink>::Handle;

    type ElemName<'a> = <RcDom as TreeSink>::ElemName<'a>;

    // Override the parse_error method to add line numbers to the error messages.
    fn parse_error(&self, msg: Cow<'static, str>) {
        let msg_with_line = format!("Line {}: {}", self.current_line.get(), msg);
        self.dom.parse_error(Cow::Owned(msg_with_line));
    }

    // Override to track the current line number.
    fn set_current_line(&self, line: u64) {
        self.current_line.set(line);
    }

    // Override to return RcDomWithLineNumbers instead of RcDom.
    fn finish(self) -> Self::Output {
        self
    }

    // Override to record the current line number for each created element handle.
    fn create_element(
        &self,
        name: QualName,
        attrs: Vec<Attribute>,
        flags: ElementFlags,
    ) -> Self::Handle {
        let h = self.dom.create_element(name, attrs, flags);
        let key = Rc::as_ptr(&h);
        let line = self.current_line.get();
        self.node_line_map.borrow_mut().insert(key, line);
        h
    }

    // Delegate all other methods to RcDom.
    delegate! {
        to self.dom {
            fn get_document(&self) -> Self::Handle;

            fn elem_name<'a>(&'a self, target: &'a Self::Handle) -> ExpandedName<'a>;

            fn create_comment(&self, text: StrTendril) -> Self::Handle;

            fn create_pi(&self, target: StrTendril, data: StrTendril) -> Self::Handle;

            fn append(&self, parent: &Self::Handle, child: NodeOrText<Self::Handle>);

            fn append_based_on_parent_node(
                &self,
                element: &Self::Handle,
                prev_element: &Self::Handle,
                child: NodeOrText<Self::Handle>,
            );

            fn append_doctype_to_document(
                &self,
                name: StrTendril,
                public_id: StrTendril,
                system_id: StrTendril,
            );

            fn mark_script_already_started(&self, node: &Self::Handle);

            fn pop(&self, node: &Self::Handle);

            fn get_template_contents(&self, target: &Self::Handle) -> Self::Handle;

            fn same_node(&self, x: &Self::Handle, y: &Self::Handle) -> bool;

            fn set_quirks_mode(&self, mode: QuirksMode);

            fn append_before_sibling(
                &self,
                sibling: &Self::Handle,
                new_node: NodeOrText<Self::Handle>,
            );

            fn add_attrs_if_missing(&self, target: &Self::Handle, attrs: Vec<Attribute>);

            fn associate_with_form(
                &self,
                target: &Self::Handle,
                form: &Self::Handle,
                nodes: (&Self::Handle, Option<&Self::Handle>),
            );

            fn remove_from_parent(&self, target: &Self::Handle);

            fn reparent_children(&self, node: &Self::Handle, new_parent: &Self::Handle);

            fn is_mathml_annotation_xml_integration_point(&self, handle: &Self::Handle) -> bool;
        }
    }
}
