//! Augments the content attribute list for each element with a description found in the Attributes table.

use std::collections::{HashMap, HashSet};
use std::io;
use std::rc::Rc;

use html5ever::tendril::StrTendril;
use html5ever::{local_name, namespace_url, ns, LocalName, QualName};
use markup5ever_rcdom::{Handle, NodeData};

use crate::dom_utils::{self, NodeHandleExt};
use crate::parser;

#[derive(Debug, Default)]
struct Descriptions {
    /// The default description, as a list of nodes.
    default: Vec<Handle>,

    /// The variant description, if any, as an unparsed string.
    variant: Option<StrTendril>,
}

#[derive(Debug)]
struct Edit {
    /// Handle on the <dd> element which is to be filled in.
    dd: Handle,

    /// The data-x attribute which must be described.
    key: StrTendril,

    /// Whether this location has requested the variant/alternate description.
    wants_variant_description: bool,

    /// Whether this is described as having "special semantics" and so must be
    /// formatted differently.
    has_special_semantics: bool,
}

pub struct Processor {
    /// Map from attribute key (e.g., attr-elem-someattribute) to the
    /// descriptions found in the Attributes table.
    attributes: HashMap<StrTendril, Descriptions>,

    /// List of <dd> nodes in Content attributes sections that need to be filled in.
    edits: Vec<Edit>,
}

impl Processor {
    pub fn new() -> Self {
        Processor {
            attributes: HashMap::new(),
            edits: Vec::new(),
        }
    }

    pub fn visit(&mut self, node: &Handle) {
        // We're looking for a <table id="attributes-1"> (which is under the Attributes heading).
        if node.is_html_element(&local_name!("table")) && node.has_id("attributes-1") {
            self.index_attribute_table(node);
        }

        // We're looking for the following:
        // <dl class="element">
        //   ...
        //   <dt><span data-x="concept-element-attributes">Content attributes</span>:</dt>
        //   <dd><span>Global attributes</span></dd>
        //   <dd><span data-x="attr-a-href">href</span></dd>
        //   <dd><span data-x="attr-a-someattribute">someattribute</span></dd>
        //   ...
        fn is_content_attribute_dt(dt: &Handle) -> bool {
            if !dt.is_html_element(&local_name!("dt")) {
                return false;
            }
            match dt.parent_node() {
                Some(p) if p.is_html_element(&local_name!("dl")) && p.has_class("element") => (),
                _ => return false,
            }
            let data_x = QualName::new(None, ns!(), LocalName::from("data-x"));
            dt.any_child(|c| c.attribute_is(&data_x, "concept-element-attributes"))
        }
        if is_content_attribute_dt(node) {
            self.index_attribute_list(node);
        }
    }

    fn index_attribute_table(&mut self, table: &Handle) {
        let tbody = match table
            .children
            .borrow()
            .iter()
            .find(|n| n.is_html_element(&local_name!("tbody")))
        {
            Some(tbody) => tbody.clone(),
            None => return,
        };
        for row in tbody
            .children
            .borrow()
            .iter()
            .filter(|c| c.is_html_element(&local_name!("tr")))
        {
            // Each row is expected to have this structure:
            // <tr>
            //   <th> <code data-x>someattribute</code>
            //   <td> <code data-x="attr-a-someattribute">a</code>; <code data-x="attr-b-someattribute">b</code>; ...
            //   <td> Description of how someattribute applies to a, b, etc.
            //   <td> Description if the valid values
            // And we want to extract the descriptions so that we can later insert them
            // alongside the definitions of attr-a-someattribute, etc.
            let row_children = row.children.borrow();
            let mut tds = row_children
                .iter()
                .filter(|c| c.is_html_element(&local_name!("td")));
            let (keys_td, description_td) = match (tds.next(), tds.next()) {
                (Some(a), Some(b)) => (a, b),
                _ => continue,
            };

            // If a single row describes the same element multiple times, we don't need to repeat it.
            // StrTendril doesn't have logical interior mutability, so this Clippy warning is overzealous.
            #[allow(clippy::mutable_key_type)]
            let mut seen_this_row: HashSet<StrTendril> = HashSet::new();

            // These will be strings like "attr-input-maxlength", which identify particular element-attribute pairs.
            let data_x = QualName::new(None, ns!(), LocalName::from("data-x"));
            for attr_key in keys_td
                .children
                .borrow()
                .iter()
                .filter_map(|c| c.get_attribute(&data_x).filter(|v| !v.is_empty()))
            {
                // If this row describes the the same attribute, with the same
                // identifier, for multiple elements (like attr-fae-form and
                // attr-dim-width), these aren't actually distinct descriptions
                // and we need not join them.
                if !seen_this_row.insert(attr_key.clone()) {
                    continue;
                }

                // Find the <!-- or: --> comment, if one exists, and extract its contents.
                let description = description_td.children.borrow();
                let mut variant_comment = None;
                let mut variant_str = None;
                for node in description.iter() {
                    if let NodeData::Comment { ref contents } = node.data {
                        if contents.trim().starts_with("or:") {
                            variant_comment = Some(node);
                            variant_str = Some(StrTendril::from(contents.trim()[3..].trim_start()));
                        }
                    }
                }

                // Store the (already parsed) ordinary description. If a variant
                // comment exists, omit it and instead store its unparsed
                // string.
                let descriptions = Descriptions {
                    default: description_td
                        .children
                        .borrow()
                        .iter()
                        .filter(|c| variant_comment.map_or(true, |vc| !Rc::ptr_eq(c, vc)))
                        .map(|c| c.deep_clone())
                        .collect(),
                    variant: variant_str,
                };
                let existing = self.attributes.entry(attr_key).or_default();
                if existing.default.is_empty() {
                    existing.default = descriptions.default;
                } else if !descriptions.default.is_empty() {
                    if let NodeData::Text { ref contents } = existing.default.last().unwrap().data {
                        let mut borrow = contents.borrow_mut();
                        if let Some(last_non_ws) = borrow.rfind(|c: char| !c.is_ascii_whitespace())
                        {
                            let to_remove = borrow.len32() - (last_non_ws as u32) - 1;
                            borrow.pop_back(to_remove);
                        }
                    }
                    existing.default.push(Handle::create_text_node("; "));
                    existing.default.extend(descriptions.default.into_iter());
                }
                if existing.variant.is_none() {
                    existing.variant = descriptions.variant;
                } else if descriptions.variant.is_some() {
                    let existing_variant = existing.variant.as_mut().unwrap();
                    existing_variant.push_slice("; ");
                    existing_variant.push_tendril(&descriptions.variant.unwrap());
                }
            }
        }
    }

    fn index_attribute_list(&mut self, dt: &Handle) {
        // If a <dd> contains <!-- no-annotate -->, it is not annotated.
        // If it contains <!-- variant -->, the description found in a <!-- or: ... --> comment is used instead.
        // If it mentions "special semantics", it is joined with a colon rather than an em dash.
        let data_x = QualName::new(None, ns!(), LocalName::from("data-x"));
        let parent = dt.parent_node().unwrap();
        let children = parent.children.borrow();
        self.edits.extend(
            children
                .iter()
                .skip_while(|n| !Rc::ptr_eq(n, dt))
                .skip(1)
                .filter(|n| n.is_element())
                .take_while(|e| e.is_html_element(&local_name!("dd")))
                .filter_map(|dd| {
                    let mut can_annotate = true;
                    let mut wants_variant_description = false;
                    let mut has_special_semantics = false;
                    let mut key = None;
                    dom_utils::scan_dom(dd, &mut |n| match &n.data {
                        NodeData::Comment { ref contents } if contents.trim() == "no-annotate" => {
                            can_annotate = false;
                        }
                        NodeData::Comment { ref contents } if contents.trim() == "variant" => {
                            wants_variant_description = true;
                        }
                        NodeData::Text { ref contents }
                            if contents.borrow().contains("has special semantics") =>
                        {
                            has_special_semantics = true;
                        }
                        NodeData::Element { .. } => {
                            if key.is_none() {
                                key = n.get_attribute(&data_x);
                            }
                        }
                        _ => (),
                    });
                    match (can_annotate, key) {
                        (true, Some(key)) => Some(Edit {
                            dd: dd.clone(),
                            key,
                            wants_variant_description,
                            has_special_semantics,
                        }),
                        _ => None,
                    }
                }),
        );
    }

    pub async fn apply(self) -> io::Result<()> {
        let em_dash = StrTendril::from(" \u{2014} ");

        for Edit {
            dd,
            key,
            wants_variant_description,
            has_special_semantics,
        } in self.edits
        {
            // Find the requested description to insert at this point.
            let descriptions = match self.attributes.get(&key) {
                Some(descriptions) => descriptions,
                None => continue,
            };
            let mut description: Vec<Handle> = match descriptions {
                Descriptions {
                    variant: Some(ref variant),
                    ..
                } if wants_variant_description => {
                    parser::parse_fragment_async(variant[..].as_bytes(), &dd).await?
                }
                _ if wants_variant_description => {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!(
                            "Attribute {key} wants variant description, but no <!--or--> was found"
                        ),
                    ))
                }
                Descriptions { ref default, .. } => {
                    default.iter().map(|n| n.deep_clone()).collect()
                }
            };

            let mut dd_children = dd.children.borrow_mut();
            if has_special_semantics {
                // Replace the trailing period with a separating colon.
                if let Some(NodeData::Text { contents }) = dd_children.last_mut().map(|n| &n.data) {
                    let mut text = contents.borrow_mut();
                    *text = StrTendril::from(
                        text.trim_end_matches(|c: char| c.is_ascii_whitespace() || c == '.'),
                    );
                    text.push_slice(": ");
                }
            } else {
                // Insert an em dash.
                description.insert(0, Handle::create_text_node(em_dash.clone()));
            }

            // Insert the description.
            for child in description.iter_mut() {
                child.parent.set(Some(Rc::downgrade(&dd)));
            }
            dd_children.extend(description);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::{parse_document_async, tests::serialize_for_test};

    #[tokio::test]
    async fn test_simple() -> io::Result<()> {
        // This is a simple document with enough stuff in it. Elements are shown
        // before and after the attributes table, to demonstrate that this is
        // not sensitive to which order they occur in (i.e., these could be
        // reordered in the HTML spec).
        let document = parse_document_async(
            r#"
<h3>The a element</h3>
<dl class="element">
    <dt>Categories
    <dd>Flow content
    <dt><span data-x="concept-element-attributes">Content attributes</span>
    <dd><code data-x="attr-a-href">href</code>
</dl>
<h3>Attributes</h3>
<table id="attributes-1"><tbody>
    <tr><th><code data-x>href</code><td><code data-x="attr-a-href">a</code>; <code data-x="attr-area-href">area</code><td>Destination of the <span>hyperlink</span>
</tbody></table>
<h3>The area element</h3>
<dl class="element">
    <dt>Categories
    <dd>Flow content
    <dt><span data-x="concept-element-attributes">Content attributes</span>
    <dd><code data-x="attr-area-href">href</code>
</dl>
            "#.trim().as_bytes()).await?;
        let mut proc = Processor::new();
        dom_utils::scan_dom(&document, &mut |h| proc.visit(h));
        proc.apply().await?;
        assert_eq!(
            serialize_for_test(&[document]),
            r#"
<html><head></head><body><h3>The a element</h3>
<dl class="element">
    <dt>Categories
    </dt><dd>Flow content
    </dd><dt><span data-x="concept-element-attributes">Content attributes</span>
    </dt><dd><code data-x="attr-a-href">href</code>
 — Destination of the <span>hyperlink</span>
</dd></dl>
<h3>Attributes</h3>
<table id="attributes-1"><tbody>
    <tr><th><code data-x="">href</code></th><td><code data-x="attr-a-href">a</code>; <code data-x="attr-area-href">area</code></td><td>Destination of the <span>hyperlink</span>
</td></tr></tbody></table>
<h3>The area element</h3>
<dl class="element">
    <dt>Categories
    </dt><dd>Flow content
    </dd><dt><span data-x="concept-element-attributes">Content attributes</span>
    </dt><dd><code data-x="attr-area-href">href</code>
 — Destination of the <span>hyperlink</span>
</dd></dl></body></html>
            "#.trim()
        );
        Ok(())
    }

    #[tokio::test]
    async fn test_variant() -> io::Result<()> {
        // This checks that <!-- variant --> and <!-- or: --> work correctly.
        // i.e., the variant description is used where requested
        let document = parse_document_async(
            r#"
<h3>The a element</h3>
<dl class="element">
    <dt><span data-x="concept-element-attributes">Content attributes</span>
    <dd><code data-x="attr-a-href">href</code>
</dl>
<h3>Attributes</h3>
<table id="attributes-1"><tbody>
    <tr><th><code data-x>href</code><td><code data-x="attr-a-href">a</code>; <code data-x="attr-area-href">area</code><td>Destination of the <span>hyperlink</span><!-- or: click on <span>shapes</span>! -->
</tbody></table>
<h3>The area element</h3>
<dl class="element">
    <dt><span data-x="concept-element-attributes">Content attributes</span>
    <dd><code data-x="attr-area-href">href</code><!-- variant -->
</dl>
            "#.trim().as_bytes()).await?;
        let mut proc = Processor::new();
        dom_utils::scan_dom(&document, &mut |h| proc.visit(h));
        proc.apply().await?;
        assert_eq!(
            serialize_for_test(&[document]),
            r#"
<html><head></head><body><h3>The a element</h3>
<dl class="element">
    <dt><span data-x="concept-element-attributes">Content attributes</span>
    </dt><dd><code data-x="attr-a-href">href</code>
 — Destination of the <span>hyperlink</span>
</dd></dl>
<h3>Attributes</h3>
<table id="attributes-1"><tbody>
    <tr><th><code data-x="">href</code></th><td><code data-x="attr-a-href">a</code>; <code data-x="attr-area-href">area</code></td><td>Destination of the <span>hyperlink</span><!-- or: click on <span>shapes</span>! -->
</td></tr></tbody></table>
<h3>The area element</h3>
<dl class="element">
    <dt><span data-x="concept-element-attributes">Content attributes</span>
    </dt><dd><code data-x="attr-area-href">href</code><!-- variant -->
 — click on <span>shapes</span>!</dd></dl></body></html>
            "#.trim()
        );
        Ok(())
    }

    #[tokio::test]
    async fn test_special_semantics() -> io::Result<()> {
        // Checks that the special rules for using : instead of an em dash work.
        let document = parse_document_async(
            r#"
<h3>The a element</h3>
<dl class="element">
    <dt><span data-x="concept-element-attributes">Content attributes</span>
    <dd>Also, the <code data-x="attr-a-name">name</code> attribute <span data-x="attr-a-name">has special semantics</span> on this element.
</dl>
<h3>Attributes</h3>
<table id="attributes-1"><tbody>
    <tr><th><code data-x>name</code><td><code data-x="attr-a-name">a</code><td>Anchor name
</tbody></table>
            "#.trim().as_bytes()).await?;
        let mut proc = Processor::new();
        dom_utils::scan_dom(&document, &mut |h| proc.visit(h));
        proc.apply().await?;
        assert_eq!(
            serialize_for_test(&[document]),
            r#"
<html><head></head><body><h3>The a element</h3>
<dl class="element">
    <dt><span data-x="concept-element-attributes">Content attributes</span>
    </dt><dd>Also, the <code data-x="attr-a-name">name</code> attribute <span data-x="attr-a-name">has special semantics</span> on this element: Anchor name
</dd></dl>
<h3>Attributes</h3>
<table id="attributes-1"><tbody>
    <tr><th><code data-x="">name</code></th><td><code data-x="attr-a-name">a</code></td><td>Anchor name
</td></tr></tbody></table></body></html>
            "#.trim()
        );
        Ok(())
    }

    #[tokio::test]
    async fn test_special_semantics_multiple() -> io::Result<()> {
        // Checks that the special rules for joining any special semantics with a ; work.
        let document = parse_document_async(
            r#"
<h3>The a element</h3>
<dl class="element">
    <dt><span data-x="concept-element-attributes">Content attributes</span>
    <dd>Also, the <code data-x="attr-a-name">name</code> attribute <span data-x="attr-a-name">has special semantics</span> on this element.
</dl>
<h3>Attributes</h3>
<table id="attributes-1"><tbody>
    <tr><th><code data-x>name</code><td><code data-x="attr-a-name">a</code><td>Anchor name
    <tr><th><code data-x>name</code><td><code data-x="attr-a-name">a</code><td>Name of the anchor
</tbody></table>
            "#.trim().as_bytes()).await?;
        let mut proc = Processor::new();
        dom_utils::scan_dom(&document, &mut |h| proc.visit(h));
        proc.apply().await?;
        assert_eq!(
            serialize_for_test(&[document]),
            r#"
<html><head></head><body><h3>The a element</h3>
<dl class="element">
    <dt><span data-x="concept-element-attributes">Content attributes</span>
    </dt><dd>Also, the <code data-x="attr-a-name">name</code> attribute <span data-x="attr-a-name">has special semantics</span> on this element: Anchor name; Name of the anchor
</dd></dl>
<h3>Attributes</h3>
<table id="attributes-1"><tbody>
    <tr><th><code data-x="">name</code></th><td><code data-x="attr-a-name">a</code></td><td>Anchor name
    </td></tr><tr><th><code data-x="">name</code></th><td><code data-x="attr-a-name">a</code></td><td>Name of the anchor
</td></tr></tbody></table></body></html>
            "#.trim()
        );
        Ok(())
    }

    #[tokio::test]
    async fn test_identical_links() -> io::Result<()> {
        // This checks the same identifier can be linked multiple times without
        // repeating the description.
        let document = parse_document_async(
            r#"
<h3>The img element</h3>
<dl class="element">
    <dt><span data-x="concept-element-attributes">Content attributes</span>
    <dd><code data-x="attr-dim-width">width</code>
</dl>
<h3>The video element</h3>
<dl class="element">
    <dt><span data-x="concept-element-attributes">Content attributes</span>
    <dd><code data-x="attr-dim-width">width</code>
</dl>
<h3>Attributes</h3>
<table id="attributes-1"><tbody>
    <tr><th><code data-x>width</code><td><code data-x="attr-dim-width">img</code>; <code data-x="attr-dim-width">video</code><td>Horizontal dimension
</tbody></table>
            "#.trim().as_bytes()).await?;
        let mut proc = Processor::new();
        dom_utils::scan_dom(&document, &mut |h| proc.visit(h));
        proc.apply().await?;
        assert_eq!(
            serialize_for_test(&[document]),
            r#"
<html><head></head><body><h3>The img element</h3>
<dl class="element">
    <dt><span data-x="concept-element-attributes">Content attributes</span>
    </dt><dd><code data-x="attr-dim-width">width</code>
 — Horizontal dimension
</dd></dl>
<h3>The video element</h3>
<dl class="element">
    <dt><span data-x="concept-element-attributes">Content attributes</span>
    </dt><dd><code data-x="attr-dim-width">width</code>
 — Horizontal dimension
</dd></dl>
<h3>Attributes</h3>
<table id="attributes-1"><tbody>
    <tr><th><code data-x="">width</code></th><td><code data-x="attr-dim-width">img</code>; <code data-x="attr-dim-width">video</code></td><td>Horizontal dimension
</td></tr></tbody></table></body></html>
            "#.trim()
        );
        Ok(())
    }
}
