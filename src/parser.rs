//! This module provides some mild integration between the html5ever parser and async I/O.

use std::io;

use html5ever::driver::{self, ParseOpts, Parser};
use html5ever::tendril::{ByteTendril, TendrilSink};
use html5ever::tokenizer::TokenizerOpts;
use html5ever::tree_builder::TreeBuilderOpts;
use markup5ever_rcdom::Handle;
use tokio::io::{AsyncRead, AsyncReadExt};

use crate::rcdom_with_line_numbers::RcDomWithLineNumbers;

async fn parse_internal_async<R: AsyncRead + Unpin>(
    parser: Parser<RcDomWithLineNumbers>,
    mut r: R,
) -> io::Result<RcDomWithLineNumbers> {
    let mut tendril_sink = parser.from_utf8();

    // This draws on the structure of the sync tendril read_from.
    // https://docs.rs/tendril/latest/tendril/stream/trait.TendrilSink.html#method.read_from
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
    Ok(dom)
}

pub async fn parse_fragment_async<R: AsyncRead + Unpin>(
    r: R,
    context: &Handle,
) -> io::Result<Vec<Handle>> {
    let parser = driver::parse_fragment_for_element(
        RcDomWithLineNumbers::default(),
        create_error_opts(),
        context.clone(),
        false,
        None,
    );

    let dom = parse_internal_async(parser, r).await?;
    dom.create_error_from_parse_errors()?;

    let document = dom.document();
    let mut new_children = document.children.take()[0].children.take();
    for new_child in new_children.iter_mut() {
        new_child.parent.take();
    }
    Ok(new_children)
}

pub async fn parse_document_async<R: AsyncRead + Unpin>(r: R) -> io::Result<RcDomWithLineNumbers> {
    let parser = driver::parse_document(RcDomWithLineNumbers::default(), create_error_opts());
    let dom = parse_internal_async(parser, r).await?;
    dom.create_error_from_parse_errors()?;

    Ok(dom)
}

fn create_error_opts() -> ParseOpts {
    ParseOpts {
        tokenizer: TokenizerOpts {
            exact_errors: true,
            ..Default::default()
        },
        tree_builder: TreeBuilderOpts {
            exact_errors: true,
            ..Default::default()
        },
    }
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
        let parsed = parse_document_async("<!DOCTYPE html><table></table>".as_bytes()).await?;
        let document = parsed.document().clone();
        let body = document.children.borrow()[1].children.borrow()[1].clone();
        assert!(body.is_html_element(&local_name!("body")));
        let table = body.children.borrow()[0].clone();
        assert!(table.is_html_element(&local_name!("table")));
        let children = parse_fragment_async("<tbody>".as_bytes(), &table).await?;
        assert_eq!(serialize_for_test(&children), "<tbody></tbody>");
        Ok(())
    }

    #[tokio::test]
    async fn test_document_error_line_number() -> io::Result<()> {
        let result = parse_document_async(
            "<!DOCTYPE html>Hello\n<strong><em>world</strong></em>".as_bytes(),
        )
        .await;

        let error = result.unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert!(error.to_string().contains("Line 2: "));

        Ok(())
    }

    // See https://github.com/whatwg/html-build/issues/301
    #[tokio::test]
    async fn test_document_error_line_number_pre() -> io::Result<()> {
        let result = parse_document_async(
            r##"<!DOCTYPE html>
<pre>h1&gt;
</pre>
<p>Test 2</span>"##
                .as_bytes(),
        )
        .await;

        let error = result.unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert!(error.to_string().contains("Line 4: "));

        Ok(())
    }

    #[tokio::test]
    async fn test_document_error_exact() -> io::Result<()> {
        let result = parse_document_async("<!DOCTYPE html>&asdf;".as_bytes()).await;

        let error = result.unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert!(error.to_string().contains("&asdf;"));

        Ok(())
    }

    #[tokio::test]
    async fn test_fragment_error_line_number() -> io::Result<()> {
        let parsed = parse_document_async("<!DOCTYPE html>".as_bytes()).await?;
        let document = parsed.document().clone();
        let body = document.children.borrow()[1].children.borrow()[1].clone();
        assert!(body.is_html_element(&local_name!("body")));
        let result = parse_fragment_async(
            "Hello \n\n<strong><em>world</strong></em>".as_bytes(),
            &body,
        )
        .await;

        let error = result.unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert!(error.to_string().contains("Line 3: "));

        Ok(())
    }

    #[tokio::test]
    async fn test_fragment_error_exact() -> io::Result<()> {
        let parsed = parse_document_async("<!DOCTYPE html>".as_bytes()).await?;
        let document = parsed.document().clone();
        let body = document.children.borrow()[1].children.borrow()[1].clone();
        assert!(body.is_html_element(&local_name!("body")));
        let result = parse_fragment_async("&asdf;".as_bytes(), &body).await;

        let error = result.unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert!(error.to_string().contains("&asdf;"));

        Ok(())
    }
}
