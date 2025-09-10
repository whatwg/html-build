//! Replaces <!--BOILERPLATE filename.inc--> comments.
//! These can either be comment nodes (in which case the resulting fragment will
//! be inserted), or the complete value of an element's attribute (in which case
//! the text will become the attribute value).

use std::io;
use std::path::{Path, PathBuf};

use html5ever::tendril::{self, SendTendril};
use html5ever::{Attribute, LocalName, QualName, local_name};
use markup5ever_rcdom::{Handle, NodeData};
use tokio::fs::File;
use tokio::task::JoinHandle;

use crate::dom_utils::NodeHandleExt;
use crate::io_utils::{async_error, is_safe_path, read_to_str_tendril};
use crate::parser;

type SendStrTendril = SendTendril<tendril::fmt::UTF8>;

enum Edit {
    ReplaceHTML(Handle, JoinHandle<io::Result<File>>),
    ReplaceAttr(Handle, QualName, JoinHandle<io::Result<SendStrTendril>>),
    ReplaceText(Handle, JoinHandle<io::Result<SendStrTendril>>),
}

pub struct Processor {
    /// Path to look for boilerplate files.
    path: PathBuf,

    /// Path to look for example files.
    example_path: PathBuf,

    /// Changes to be made in the apply step.
    edits: Vec<Edit>,
}

impl Processor {
    pub fn new(path: impl Into<PathBuf>, example_path: impl Into<PathBuf>) -> Self {
        Self {
            path: path.into(),
            example_path: example_path.into(),
            edits: vec![],
        }
    }

    /// Should be called for each node in the document.
    /// Identifies replacements which will be needed, and starts the necessary
    /// I/O.
    pub fn visit(&mut self, node: &Handle) {
        match &node.data {
            // BOILERPLATE comments will need to be replaced with their
            // corresponding HTML, parsed. Open the file so that we can do so on
            // demand.
            NodeData::Comment { contents } if contents.starts_with("BOILERPLATE ") => {
                let path = Path::new(contents[12..].trim());
                let file = if is_safe_path(path) {
                    tokio::spawn(File::open(self.path.join(path)))
                } else {
                    async_error(io::Error::new(
                        io::ErrorKind::PermissionDenied,
                        "cannot traverse to a parent directory in {path}",
                    ))
                };
                self.edits.push(Edit::ReplaceHTML(node.clone(), file));
            }
            // Pseudo-comments can also appear in element attributes. These are
            // not parsed as HTML, so we simply want to read them into memory so
            // they can be replaced.
            NodeData::Element { attrs, .. } => {
                for Attribute { name, value } in attrs.borrow().iter() {
                    if value.starts_with("<!--BOILERPLATE ") && value.ends_with("-->") {
                        let path = Path::new(value[16..value.len() - 3].trim());
                        let file_contents = if is_safe_path(path) {
                            read_to_str_tendril(self.path.join(path))
                        } else {
                            async_error(io::Error::new(
                                io::ErrorKind::PermissionDenied,
                                "cannot traverse to a parent directory in {path}",
                            ))
                        };
                        self.edits.push(Edit::ReplaceAttr(
                            node.clone(),
                            name.clone(),
                            file_contents,
                        ));
                    }
                }
            }
            // <pre> and <pre><code> which contain EXAMPLE also need to be
            // replaced, but as plain text. These are loaded from the "examples"
            // directory instead.
            NodeData::Text { contents } => {
                let borrowed_contents = contents.borrow();
                let text = borrowed_contents.trim();
                if !text.starts_with("EXAMPLE ") {
                    return;
                }
                const PRE: LocalName = local_name!("pre");
                const CODE: LocalName = local_name!("code");
                let has_suitable_parent = node.parent_node().is_some_and(|p| {
                    p.is_html_element(&PRE)
                        || (p.is_html_element(&CODE)
                            && p.parent_node().is_some_and(|p2| p2.is_html_element(&PRE)))
                });
                if has_suitable_parent {
                    let path = Path::new(text[8..].trim());
                    let file_contents = if is_safe_path(path) {
                        read_to_str_tendril(self.example_path.join(path))
                    } else {
                        async_error(io::Error::new(
                            io::ErrorKind::PermissionDenied,
                            "cannot traverse to a parent directory in {path}",
                        ))
                    };
                    self.edits
                        .push(Edit::ReplaceText(node.clone(), file_contents))
                }
            }
            _ => (),
        }
    }

    /// Applies the required replacements, in order.
    pub async fn apply(self) -> io::Result<()> {
        for edit in self.edits {
            match edit {
                // When parsing HTML, we need the context it's in so that the
                // context-sensitive parsing behavior works correctly.
                Edit::ReplaceHTML(node, replacement) => {
                    let context = match node.parent_node() {
                        Some(n) => n,
                        _ => continue,
                    };
                    let file: File = replacement.await??;
                    let new_children = parser::parse_fragment_async(file, &context).await?;
                    node.replace_with(new_children);
                }
                Edit::ReplaceAttr(element, ref attr, replacement) => {
                    element.set_attribute(attr, replacement.await??.into());
                }
                Edit::ReplaceText(element, replacement) => match element.data {
                    NodeData::Text { ref contents } => {
                        contents.replace(replacement.await??.into());
                    }
                    _ => panic!("not text"),
                },
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dom_utils;
    use crate::parser::{parse_document_async, tests::serialize_for_test};
    use tempfile::TempDir;

    #[tokio::test]
    async fn test_replace_boilerplate_comment() -> io::Result<()> {
        let boilerplate_dir = TempDir::new()?;
        tokio::fs::write(
            boilerplate_dir.path().join("languages"),
            "<tr><td>en<td>English",
        )
        .await?;
        let parsed = parse_document_async(
            "<!DOCTYPE html><table><!--BOILERPLATE languages--></table>".as_bytes(),
        )
        .await?;
        let document = parsed.document().clone();
        let mut proc = Processor::new(boilerplate_dir.path(), Path::new("."));
        dom_utils::scan_dom(&document, &mut |h| proc.visit(h));
        proc.apply().await?;
        assert_eq!(
            serialize_for_test(&[document]),
            "<!DOCTYPE html><html><head></head><body><table><tbody><tr><td>en</td><td>English</td></tr></tbody></table></body></html>"
        );
        Ok(())
    }

    #[tokio::test]
    async fn test_replace_boilerplate_attribute() -> io::Result<()> {
        let boilerplate_dir = TempDir::new()?;
        tokio::fs::write(
            boilerplate_dir.path().join("data.url"),
            "data:text/html,Hello, world!",
        )
        .await?;
        let parsed = parse_document_async(
            "<!DOCTYPE html><a href=\"<!--BOILERPLATE data.url-->\">hello</a>".as_bytes(),
        )
        .await?;
        let document = parsed.document().clone();
        let mut proc = Processor::new(boilerplate_dir.path(), Path::new("."));
        dom_utils::scan_dom(&document, &mut |h| proc.visit(h));
        proc.apply().await?;
        assert_eq!(
            serialize_for_test(&[document]),
            "<!DOCTYPE html><html><head></head><body><a href=\"data:text/html,Hello, world!\">hello</a></body></html>"
        );
        Ok(())
    }

    #[tokio::test]
    async fn test_replace_example() -> io::Result<()> {
        let example_dir = TempDir::new()?;
        tokio::fs::write(example_dir.path().join("ex1"), "first").await?;
        tokio::fs::write(example_dir.path().join("ex2"), "second").await?;
        tokio::fs::write(example_dir.path().join("ignored"), "bad").await?;
        let parsed =
            parse_document_async("<!DOCTYPE html><pre>EXAMPLE ex1</pre><pre><code class=html>\nEXAMPLE ex2  </code></pre><p>EXAMPLE ignored</p>".as_bytes())
                .await?;
        let document = parsed.document().clone();
        let mut proc = Processor::new(Path::new("."), example_dir.path());
        dom_utils::scan_dom(&document, &mut |h| proc.visit(h));
        proc.apply().await?;
        assert_eq!(
            serialize_for_test(&[document]),
            "<!DOCTYPE html><html><head></head><body><pre>first</pre><pre><code class=\"html\">second</code></pre><p>EXAMPLE ignored</p></body></html>"
        );
        Ok(())
    }

    #[tokio::test]
    async fn test_errors_unsafe_paths() -> io::Result<()> {
        let bad_path_examples = [
            "<!DOCTYPE html><body><!--BOILERPLATE /etc/passwd-->",
            "<!DOCTYPE html><body><pre data-x=\"<!--BOILERPLATE src/../../foo-->\"></pre>",
            "<!DOCTYPE html><body><pre>EXAMPLE ../foo</pre>",
        ];
        for example in bad_path_examples {
            let parsed = parse_document_async(example.as_bytes()).await?;
            let document = parsed.document().clone();
            let mut proc = Processor::new(Path::new("."), Path::new("."));
            dom_utils::scan_dom(&document, &mut |h| proc.visit(h));
            let result = proc.apply().await;
            assert!(matches!(result, Err(e) if e.kind() == io::ErrorKind::PermissionDenied));
        }
        Ok(())
    }
}
