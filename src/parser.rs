//! This module provides some mild integration between the html5ever parser and async I/O.

use std::borrow::Cow;
use std::io;

use html5ever::buffer_queue::BufferQueue;
use html5ever::tendril::{self, stream::Utf8LossyDecoder, ByteTendril, StrTendril, TendrilSink};
use html5ever::tokenizer::{Tokenizer, TokenizerOpts, TokenizerResult};
use html5ever::tree_builder::{TreeBuilder, TreeSink};
use markup5ever_rcdom::{Handle, RcDom};
use tokio::io::{AsyncRead, AsyncReadExt};

struct FilteredParser<Sink: TreeSink> {
    tokenizer: Tokenizer<TreeBuilder<Sink::Handle, Sink>>,
    input_buffer: BufferQueue,
}

impl<Sink: TreeSink> TendrilSink<tendril::fmt::UTF8> for FilteredParser<Sink> {
    fn process(&mut self, t: StrTendril) {
        self.input_buffer.push_back(t);
        while let TokenizerResult::Script(_) = self.tokenizer.feed(&mut self.input_buffer) {}
    }

    fn error(&mut self, desc: Cow<'static, str>) {
        self.tokenizer.sink.sink.parse_error(desc)
    }

    type Output = Sink::Output;

    fn finish(mut self) -> Self::Output {
        while let TokenizerResult::Script(_) = self.tokenizer.feed(&mut self.input_buffer) {}
        assert!(self.input_buffer.is_empty());
        self.tokenizer.end();
        self.tokenizer.sink.sink.finish()
    }
}

impl<Sink: TreeSink> FilteredParser<Sink> {
    fn into_utf8(self) -> Utf8LossyDecoder<Self> {
        Utf8LossyDecoder::new(self)
    }
}

async fn parse_internal_async<R: AsyncRead + Unpin>(
    tb: TreeBuilder<Handle, RcDom>,
    tokenizer_opts: TokenizerOpts,
    mut r: R,
) -> io::Result<Handle> {
    let tok = Tokenizer::new(tb, tokenizer_opts);
    let mut tendril_sink = FilteredParser {
        tokenizer: tok,
        input_buffer: BufferQueue::new(),
    }
    .into_utf8();

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
