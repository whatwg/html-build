// This provides a wrapper around RcDom which tracks line numbers in the errors.

use delegate::delegate;
use html5ever::interface::TreeSink;
use html5ever::{
    Attribute, ExpandedName, QualName,
    tendril::StrTendril,
    tree_builder::{ElementFlags, NextParserState, NodeOrText, QuirksMode},
};
use markup5ever_rcdom::{Handle, RcDom};
use std::borrow::Cow;
use std::io;

pub struct RcDomWithLineNumbers {
    dom: RcDom,
    current_line: u64,
}

impl RcDomWithLineNumbers {
    // Expose out the document and errors from the inner RcDom
    pub fn document(&self) -> &Handle {
        &self.dom.document
    }

    pub fn create_error_from_parse_errors(&self) -> io::Result<()> {
        if !self.dom.errors.is_empty() {
            let error_messages = self
                .dom
                .errors
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
}

impl Default for RcDomWithLineNumbers {
    fn default() -> Self {
        Self {
            dom: RcDom::default(),
            current_line: 1,
        }
    }
}

impl TreeSink for RcDomWithLineNumbers {
    type Output = RcDomWithLineNumbers;
    type Handle = <RcDom as TreeSink>::Handle;

    // Override the parse_error method to add line numbers to the error messages.
    fn parse_error(&mut self, msg: Cow<'static, str>) {
        let msg_with_line = format!("Line {}: {}", self.current_line, msg);
        self.dom.parse_error(Cow::Owned(msg_with_line));
    }

    // Override to track the current line number.
    fn set_current_line(&mut self, line: u64) {
        self.current_line = line;
    }

    // Override to return RcDomWithLineNumbers instead of RcDom.
    fn finish(self) -> Self::Output {
        self
    }

    // Delegate all other methods to RcDom.
    delegate! {
        to self.dom {
            fn get_document(&mut self) -> Self::Handle;

            fn elem_name<'a>(&'a self, target: &'a Self::Handle) -> ExpandedName<'a>;

            fn create_element(
                &mut self,
                name: QualName,
                attrs: Vec<Attribute>,
                flags: ElementFlags,
            ) -> Self::Handle;

            fn create_comment(&mut self, text: StrTendril) -> Self::Handle;

            fn create_pi(&mut self, target: StrTendril, data: StrTendril) -> Self::Handle;

            fn append(&mut self, parent: &Self::Handle, child: NodeOrText<Self::Handle>);

            fn append_based_on_parent_node(
                &mut self,
                element: &Self::Handle,
                prev_element: &Self::Handle,
                child: NodeOrText<Self::Handle>,
            );

            fn append_doctype_to_document(
                &mut self,
                name: StrTendril,
                public_id: StrTendril,
                system_id: StrTendril,
            );

            fn mark_script_already_started(&mut self, node: &Self::Handle);

            fn pop(&mut self, node: &Self::Handle);

            fn get_template_contents(&mut self, target: &Self::Handle) -> Self::Handle;

            fn same_node(&self, x: &Self::Handle, y: &Self::Handle) -> bool;

            fn set_quirks_mode(&mut self, mode: QuirksMode);

            fn append_before_sibling(
                &mut self,
                sibling: &Self::Handle,
                new_node: NodeOrText<Self::Handle>,
            );

            fn add_attrs_if_missing(&mut self, target: &Self::Handle, attrs: Vec<Attribute>);

            fn associate_with_form(
                &mut self,
                target: &Self::Handle,
                form: &Self::Handle,
                nodes: (&Self::Handle, Option<&Self::Handle>),
            );

            fn remove_from_parent(&mut self, target: &Self::Handle);

            fn reparent_children(&mut self, node: &Self::Handle, new_parent: &Self::Handle);

            fn is_mathml_annotation_xml_integration_point(&self, handle: &Self::Handle) -> bool;

            fn complete_script(&mut self, node: &Self::Handle) -> NextParserState;
        }
    }
}
