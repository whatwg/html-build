//! This module provides some mild integration between the html5ever parser and async I/O.

use std::io;

use html5ever::driver::{self, Parser};
use html5ever::tendril::{ByteTendril, TendrilSink};
use markup5ever_rcdom::{Handle, RcDom};
use tokio::io::{AsyncRead, AsyncReadExt};

async fn parse_internal_async<R: AsyncRead + Unpin>(
    parser: Parser<RcDom>,
    mut r: R,
) -> io::Result<Handle> {
    let mut tendril_sink = parser.from_utf8();

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
    let parser = driver::parse_fragment_for_element(
        RcDom::default(),
        Default::default(),
        context.clone(),
        None,
    );
    let document = parse_internal_async(parser, r).await?;
    let mut new_children = document.children.take()[0].children.take();
    for new_child in new_children.iter_mut() {
        new_child.parent.take();
    }
    Ok(new_children)
}

pub async fn parse_document_async<R: AsyncRead + Unpin>(r: R) -> io::Result<Handle> {
    let parser = driver::parse_document(RcDom::default(), Default::default());
    parse_internal_async(parser, r).await
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
