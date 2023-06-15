//! This module specializes the HTML5 parser to respect the "special" void <ref>
//! element, which isn't part of standard HTML. It does so by injecting a
//! synthetic </ref> token immediately afterward.
//! It also provides some mild integration with async I/O.

use std::borrow::Cow;
use std::io;

use html5ever::buffer_queue::BufferQueue;
use html5ever::tendril::{self, stream::Utf8LossyDecoder, ByteTendril, StrTendril, TendrilSink};
use html5ever::tokenizer::{
    Tag, TagKind, Token, TokenSink, TokenSinkResult, Tokenizer, TokenizerOpts, TokenizerResult,
};
use html5ever::tree_builder::{TreeBuilder, TreeSink};
use markup5ever_rcdom::{Handle, RcDom};
use tokio::io::{AsyncRead, AsyncReadExt};

struct TokenFilter<Sink: TokenSink> {
    sink: Sink,
}

impl<Sink: TokenSink> TokenSink for TokenFilter<Sink> {
    type Handle = Sink::Handle;

    fn process_token(&mut self, token: Token, line_number: u64) -> TokenSinkResult<Self::Handle> {
        let close_tag = match token {
            Token::TagToken(Tag {
                kind: TagKind::StartTag,
                name: ref tag_name,
                ..
            }) if tag_name.eq_str_ignore_ascii_case("ref") => Some(Tag {
                kind: TagKind::EndTag,
                name: tag_name.clone(),
                self_closing: false,
                attrs: vec![],
            }),
            _ => None,
        };
        match (self.sink.process_token(token, line_number), close_tag) {
            (TokenSinkResult::Continue, Some(close_tag)) => self
                .sink
                .process_token(Token::TagToken(close_tag), line_number),
            (result, _) => result,
        }
    }

    fn end(&mut self) {
        self.sink.end()
    }

    fn adjusted_current_node_present_but_not_in_html_namespace(&self) -> bool {
        self.sink
            .adjusted_current_node_present_but_not_in_html_namespace()
    }
}

struct FilteredParser<Sink: TreeSink> {
    tokenizer: Tokenizer<TokenFilter<TreeBuilder<Sink::Handle, Sink>>>,
    input_buffer: BufferQueue,
}

impl<Sink: TreeSink> TendrilSink<tendril::fmt::UTF8> for FilteredParser<Sink> {
    fn process(&mut self, t: StrTendril) {
        self.input_buffer.push_back(t);
        while let TokenizerResult::Script(_) = self.tokenizer.feed(&mut self.input_buffer) {}
    }

    fn error(&mut self, desc: Cow<'static, str>) {
        self.tokenizer.sink.sink.sink.parse_error(desc)
    }

    type Output = Sink::Output;

    fn finish(mut self) -> Self::Output {
        while let TokenizerResult::Script(_) = self.tokenizer.feed(&mut self.input_buffer) {}
        assert!(self.input_buffer.is_empty());
        self.tokenizer.end();
        self.tokenizer.sink.sink.sink.finish()
    }
}

impl<Sink: TreeSink> FilteredParser<Sink> {
    #[allow(clippy::wrong_self_convention)]
    fn from_utf8(self) -> Utf8LossyDecoder<Self> {
        Utf8LossyDecoder::new(self)
    }
}

async fn parse_internal_async<R: AsyncRead + Unpin>(
    tb: TreeBuilder<Handle, RcDom>,
    tokenizer_opts: TokenizerOpts,
    mut r: R,
) -> io::Result<Handle> {
    let tok = Tokenizer::new(TokenFilter { sink: tb }, tokenizer_opts);
    let mut tendril_sink = FilteredParser {
        tokenizer: tok,
        input_buffer: BufferQueue::new(),
    }
    .from_utf8();

    // This draws on the structure of the sync tendril read_from.
    const BUFFER_SIZE: u32 = 128 * 1024;
    'read: loop {
        let mut tendril = ByteTendril::new();
        unsafe {
            tendril.push_uninitialized(BUFFER_SIZE);
        }
        loop {
            match r.read(&mut tendril).await {
                Ok(0) => break 'read,
                Ok(n) => {
                    tendril.pop_back(BUFFER_SIZE - n as u32);
                    tendril_sink.process(tendril);
                    break;
                }
                Err(ref e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(e) => Err(e)?,
            }
        }
    }
    let dom = tendril_sink.finish();
    Ok(dom.document)
}

pub async fn parse_fragment_async<R: AsyncRead + Unpin>(
    r: R,
    context: &Handle,
) -> io::Result<Vec<Handle>> {
    let tb =
        TreeBuilder::new_for_fragment(RcDom::default(), context.clone(), None, Default::default());
    let tokenizer_opts = TokenizerOpts {
        initial_state: Some(tb.tokenizer_state_for_context_elem()),
        ..TokenizerOpts::default()
    };
    let document = parse_internal_async(tb, tokenizer_opts, r).await?;
    let mut new_children = document.children.take()[0].children.take();
    for new_child in new_children.iter_mut() {
        new_child.parent.take();
    }
    Ok(new_children)
}

pub async fn parse_document_async<R: AsyncRead + Unpin>(r: R) -> io::Result<Handle> {
    let tb = TreeBuilder::new(RcDom::default(), Default::default());
    parse_internal_async(tb, TokenizerOpts::default(), r).await
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::dom_utils::NodeHandleExt;
    use html5ever::serialize::{SerializeOpts, TraversalScope};
    use html5ever::{local_name, serialize};
    use markup5ever_rcdom::{NodeData, SerializableHandle};

    pub(crate) fn serialize_for_test(nodes: &[Handle]) -> String {
        let mut output = vec![];
        for node in nodes {
            let traversal_scope = match node.data {
                NodeData::Document => TraversalScope::ChildrenOnly(None),
                _ => TraversalScope::IncludeNode,
            };
            serialize(
                &mut output,
                &SerializableHandle::from(node.clone()),
                SerializeOpts {
                    traversal_scope,
                    ..Default::default()
                },
            )
            .unwrap();
        }
        String::from_utf8(output).unwrap()
    }

    #[tokio::test]
    async fn test_treats_ref_as_void() -> io::Result<()> {
        // Without the token filtering, the first <ref> ends up as the second's parent.
        let document =
            parse_document_async("<!DOCTYPE html><ref spec=CSP><ref spec=SW>".as_bytes()).await?;
        assert_eq!(
            serialize_for_test(&[document]),
            "<!DOCTYPE html><html><head></head><body><ref spec=\"CSP\"></ref><ref spec=\"SW\"></ref></body></html>");
        Ok(())
    }

    #[tokio::test]
    async fn test_treats_ref_as_void_in_fragments() -> io::Result<()> {
        // Similar to the above, but in a fragment.
        let document = parse_document_async("<!DOCTYPE html>".as_bytes()).await?;
        let body = document.children.borrow()[1].children.borrow()[1].clone();
        assert!(body.is_html_element(&local_name!("body")));
        let children =
            parse_fragment_async("<ref spec=CSP><ref spec=SW>.".as_bytes(), &body).await?;
        assert_eq!(
            serialize_for_test(&children),
            "<ref spec=\"CSP\"></ref><ref spec=\"SW\"></ref>."
        );
        Ok(())
    }

    #[tokio::test]
    async fn test_fragment_respects_context() -> io::Result<()> {
        // Checks that we have the appropriate insertion mode for the element
        // we're in. This is important because of the special rules
        // surrounding, e.g., tables. If you change this to use the body as context,
        // no element at all is emitted.
        let document = parse_document_async("<!DOCTYPE html><table>".as_bytes()).await?;
        let body = document.children.borrow()[1].children.borrow()[1].clone();
        assert!(body.is_html_element(&local_name!("body")));
        let table = body.children.borrow()[0].clone();
        assert!(table.is_html_element(&local_name!("table")));
        let children = parse_fragment_async("<tbody>".as_bytes(), &table).await?;
        assert_eq!(serialize_for_test(&children), "<tbody></tbody>");
        Ok(())
    }
}
