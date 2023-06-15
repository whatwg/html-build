//! This module specializes the HTML5 serializer to omit </ref>, which is
//! treated as void by Wattsi.

use std::io::{self, Write};

use html5ever::serialize::*;
use html5ever::{namespace_url, ns, QualName};

struct WattsiSerializer<Wr: Write>(HtmlSerializer<Wr>);

impl<Wr: Write> Serializer for WattsiSerializer<Wr> {
    fn start_elem<'a, AttrIter>(&mut self, name: QualName, attrs: AttrIter) -> io::Result<()>
    where
        AttrIter: Iterator<Item = AttrRef<'a>>,
    {
        self.0.start_elem(name, attrs)
    }

    fn end_elem(&mut self, name: QualName) -> io::Result<()> {
        if name.ns == ns!(html) && &name.local == "ref" {
            return Ok(());
        }
        self.0.end_elem(name)
    }

    fn write_text(&mut self, text: &str) -> io::Result<()> {
        self.0.write_text(text)
    }

    fn write_comment(&mut self, text: &str) -> io::Result<()> {
        self.0.write_comment(text)
    }

    fn write_doctype(&mut self, name: &str) -> io::Result<()> {
        self.0.write_doctype(name)
    }

    fn write_processing_instruction(&mut self, target: &str, data: &str) -> io::Result<()> {
        self.0.write_processing_instruction(target, data)
    }
}

pub fn serialize<Wr, T>(writer: Wr, node: &T, opts: SerializeOpts) -> io::Result<()>
where
    Wr: Write,
    T: Serialize,
{
    let mut ser = WattsiSerializer(HtmlSerializer::new(writer, opts.clone()));
    node.serialize(&mut ser, opts.traversal_scope)
}
