use std::cell::RefCell;
use std::rc::Rc;

use html5ever::tendril::StrTendril;
use html5ever::{Attribute, LocalName, QualName, local_name, ns};
use markup5ever_rcdom::{Handle, Node, NodeData};

/// Extensions to the DOM interface to make manipulation more ergonomic.
pub trait NodeHandleExt {
    /// Returns a handle to the parent node, if there is one.
    fn parent_node(&self) -> Option<Self>
    where
        Self: Sized;

    /// Gets an attribute on the element, or None if absent or not an element.
    fn get_attribute(&self, name: &QualName) -> Option<StrTendril>;

    /// Returns whether the node has the named attribute.
    fn has_attribute(&self, name: &QualName) -> bool {
        self.get_attribute(name).is_some()
    }

    /// Returns true if the attribute exists and has the value mentioned.
    fn attribute_is(&self, name: &QualName, expected: &str) -> bool {
        self.get_attribute(name).as_deref() == Some(expected)
    }

    /// Sets an attribute on the element. Must be an element.
    fn set_attribute(&self, name: &QualName, value: StrTendril);

    /// Removes an attribute from the element, if present. Must be an element.
    fn remove_attribute(&self, name: &QualName);

    /// Returns true if the node is an element.
    fn is_element(&self) -> bool;

    /// Returns true if the node is an HTML element with the given tag name.
    fn is_html_element(&self, tag_name: &LocalName) -> bool;

    /// Returns true if the node is an element with the given class.
    fn has_class(&self, class: &str) -> bool;

    /// Returns true if the node is an element with any of the given classes.
    fn has_any_class(&self, classes: &[&str]) -> bool;

    /// Returns true if the node is an element with the given ID.
    fn has_id(&self, id: &str) -> bool {
        const ID: QualName = QualName {
            prefix: None,
            ns: ns!(),
            local: local_name!("id"),
        };
        self.attribute_is(&ID, id)
    }

    /// If this is a text node, returns its text.
    fn node_text(&self) -> Option<StrTendril>;

    /// Concatenate the text of the node and its descendants.
    fn text_content(&self) -> StrTendril;

    /// True if any child matches the predicate.
    fn any_child(&self, f: impl Fn(&Self) -> bool) -> bool;

    /// Appends children (without checking node type).
    fn append_children(&self, children: impl Iterator<Item = Self>);

    /// Prepends a single child to the node's children.
    fn prepend_child(&self, child: Self)
    where
        Self: Sized;

    /// Inserts children before the specified child.
    fn insert_children_before(&self, existing: &Self, new: impl Iterator<Item = Self>);

    /// Removes the node from its parent and replaces it with the nodes provided.
    /// Does nothing if the node has no parent.
    fn replace_with(&self, replacements: Vec<Self>)
    where
        Self: Sized;

    /// Removes the node from its parent.
    fn remove(&self)
    where
        Self: Sized;

    /// Clones the node and its entire subtree (including template contents).
    fn deep_clone(&self) -> Self;

    /// Create a new element, with the given children.
    fn create_element(name: LocalName) -> ElementBuilder<Self>
    where
        Self: Sized;

    /// Create a new text node.
    fn create_text_node(text: impl Into<StrTendril>) -> Self
    where
        Self: Sized;
}

/// Convenience helper for constructing nodes. Use like:
///   Handle::create_element(local_name!("a"))
///       .attribute(&local_name!("href"), "/")
///       .text("Home")
///       .build()
pub struct ElementBuilder<T: NodeHandleExt + Sized> {
    element: T,
}

impl<T: NodeHandleExt + Sized> ElementBuilder<T> {
    pub fn attribute(self, name: &LocalName, value: impl Into<StrTendril>) -> Self {
        self.element
            .set_attribute(&QualName::new(None, ns!(), name.clone()), value.into());
        self
    }

    pub fn children(self, children: impl Iterator<Item = T>) -> Self {
        self.element.append_children(children);
        self
    }

    pub fn child(self, child: T) -> Self {
        self.children(std::iter::once(child))
    }

    pub fn text(self, text: impl Into<StrTendril>) -> Self {
        self.child(<T as NodeHandleExt>::create_text_node(text))
    }

    pub fn build(self) -> T {
        self.element
    }
}

/// Recursively visits every DOM node (preorder). Template contents are visited
/// after children, but there are seldom both.
pub fn scan_dom<F: FnMut(&Handle)>(handle: &Handle, f: &mut F) {
    f(handle);

    for child in handle.children.borrow().iter() {
        scan_dom(child, f);
    }

    if let NodeData::Element {
        template_contents: ref tc,
        ..
    } = handle.data
        && let Some(ref tc_handle) = *tc.borrow()
    {
        scan_dom(tc_handle, f);
    }
}

/// Given a <dt> element, find the corresponding <dd> elements.
///
/// This is more subtle than you might immediately think, because there can be
/// multiple <dt> listing various terms with one or more common <dd>
/// definitions. We need to find the <dt> in the child list, and then skip it
/// and any other <dt>, before providing the <dd> that follow.
pub fn dt_descriptions(dt: &Handle) -> Vec<Handle> {
    assert!(dt.is_html_element(&local_name!("dt")));
    if let Some(ref dl) = dt
        .parent_node()
        .filter(|n| n.is_html_element(&local_name!("dl")))
    {
        dl.children
            .borrow()
            .iter()
            .filter(|n| n.is_element())
            .skip_while(|n| !Rc::ptr_eq(n, dt))
            .skip_while(|n| n.is_html_element(&local_name!("dt")))
            .take_while(|n| n.is_html_element(&local_name!("dd")))
            .cloned()
            .collect()
    } else {
        Vec::new()
    }
}

/// Returns the heading level (from 1 to 6) that the <h1> through <h6> declares, or None for all other nodes.
pub fn heading_level(node: &Handle) -> Option<u8> {
    let local = match node.data {
        NodeData::Element { ref name, .. } if name.ns == ns!(html) => &name.local,
        _ => return None,
    };
    match *local {
        local_name!("h1") => Some(1),
        local_name!("h2") => Some(2),
        local_name!("h3") => Some(3),
        local_name!("h4") => Some(4),
        local_name!("h5") => Some(5),
        local_name!("h6") => Some(6),
        _ => None,
    }
}

impl NodeHandleExt for Handle {
    fn parent_node(&self) -> Option<Handle> {
        let weak_parent = self.parent.take()?;
        let parent = weak_parent.upgrade().expect("dangling parent");
        self.parent.set(Some(weak_parent));
        Some(parent)
    }

    fn get_attribute(&self, name: &QualName) -> Option<StrTendril> {
        let attrs = match self.data {
            NodeData::Element { ref attrs, .. } => attrs.borrow(),
            _ => return None,
        };
        attrs
            .iter()
            .find(|a| &a.name == name)
            .map(|a| a.value.clone())
    }

    fn set_attribute(&self, name: &QualName, value: StrTendril) {
        let mut attrs = match self.data {
            NodeData::Element { ref attrs, .. } => attrs.borrow_mut(),
            _ => panic!("not an element"),
        };
        if let Some(attr) = attrs.iter_mut().find(|a| &a.name == name) {
            attr.value = value;
        } else {
            attrs.push(Attribute {
                name: name.clone(),
                value,
            });
        }
    }

    fn remove_attribute(&self, name: &QualName) {
        let mut attrs = match self.data {
            NodeData::Element { ref attrs, .. } => attrs.borrow_mut(),
            _ => panic!("not an element"),
        };
        if let Some(i) = attrs.iter().position(|a| &a.name == name) {
            attrs.remove(i);
        }
    }

    fn is_element(&self) -> bool {
        matches!(&self.data, NodeData::Element { .. })
    }

    fn is_html_element(&self, tag_name: &LocalName) -> bool {
        match &self.data {
            NodeData::Element {
                name:
                    QualName {
                        ns: ns!(html),
                        local,
                        ..
                    },
                ..
            } => local == tag_name,
            _ => false,
        }
    }

    fn has_class(&self, class: &str) -> bool {
        const CLASS: QualName = QualName {
            prefix: None,
            ns: ns!(),
            local: local_name!("class"),
        };
        self.get_attribute(&CLASS)
            .is_some_and(|v| v.split_ascii_whitespace().any(|c| c == class))
    }

    fn has_any_class(&self, classes: &[&str]) -> bool {
        const CLASS: QualName = QualName {
            prefix: None,
            ns: ns!(),
            local: local_name!("class"),
        };
        self.get_attribute(&CLASS)
            .is_some_and(|v| v.split_ascii_whitespace().any(|c| classes.contains(&c)))
    }

    fn node_text(&self) -> Option<StrTendril> {
        match &self.data {
            NodeData::Text { contents } => Some(contents.borrow().clone()),
            _ => None,
        }
    }

    fn text_content(&self) -> StrTendril {
        let mut text = StrTendril::new();
        scan_dom(self, &mut |n| {
            if let NodeData::Text { contents } = &n.data {
                text.push_tendril(&contents.borrow());
            }
        });
        text
    }

    fn any_child(&self, f: impl Fn(&Handle) -> bool) -> bool {
        self.children.borrow().iter().any(f)
    }

    fn append_children(&self, children: impl Iterator<Item = Handle>) {
        self.children.borrow_mut().extend(children.inspect(|c| {
            let old_parent = c.parent.replace(Some(Rc::downgrade(self)));
            assert!(old_parent.is_none());
        }));
    }

    fn prepend_child(&self, child: Handle) {
        let mut children = self.children.borrow_mut();
        let old_parent = child.parent.replace(Some(Rc::downgrade(self)));
        assert!(old_parent.is_none());
        children.insert(0, child);
    }

    fn insert_children_before(&self, existing: &Handle, new: impl Iterator<Item = Handle>) {
        let mut children = self.children.borrow_mut();
        let i = children
            .iter()
            .position(|c| Rc::ptr_eq(c, existing))
            .expect("corrupt child list");
        children.splice(
            i..i,
            new.inspect(|c| {
                let old_parent = c.parent.replace(Some(Rc::downgrade(self)));
                assert!(old_parent.is_none());
            }),
        );
    }

    fn replace_with(&self, replacements: Vec<Handle>) {
        let parent = match self.parent.take() {
            Some(n) => n.upgrade().expect("dangling parent"),
            _ => return,
        };
        for new_child in replacements.iter() {
            new_child.parent.replace(Some(Rc::downgrade(&parent)));
        }
        let mut children = parent.children.borrow_mut();
        let i = children
            .iter()
            .position(|c| Rc::ptr_eq(c, self))
            .expect("corrupt child list");
        children.splice(i..=i, replacements);
        self.parent.take();
    }

    fn remove(&self) {
        self.replace_with(Vec::new());
    }

    fn deep_clone(&self) -> Handle {
        use NodeData::*;
        let new_node_data = match &self.data {
            Document => Document,
            Doctype {
                name,
                public_id,
                system_id,
            } => Doctype {
                name: name.clone(),
                public_id: public_id.clone(),
                system_id: system_id.clone(),
            },
            Text { contents } => Text {
                contents: contents.clone(),
            },
            Comment { contents } => Comment {
                contents: contents.clone(),
            },
            Element {
                name,
                attrs,
                template_contents,
                mathml_annotation_xml_integration_point,
            } => Element {
                name: name.clone(),
                attrs: attrs.clone(),
                template_contents: RefCell::new(
                    template_contents
                        .borrow()
                        .as_ref()
                        .map(|tc| tc.deep_clone()),
                ),
                mathml_annotation_xml_integration_point: *mathml_annotation_xml_integration_point,
            },
            ProcessingInstruction { target, contents } => ProcessingInstruction {
                target: target.clone(),
                contents: contents.clone(),
            },
        };
        let node = Node::new(new_node_data);
        let mut children = node.children.borrow_mut();
        *children = self
            .children
            .borrow()
            .iter()
            .map(|c| c.deep_clone())
            .collect();
        for child in children.iter_mut() {
            let old_parent = child.parent.replace(Some(Rc::downgrade(&node)));
            assert!(old_parent.is_none());
        }
        drop(children);
        node
    }

    fn create_element(name: LocalName) -> ElementBuilder<Handle> {
        let new_node_data = NodeData::Element {
            name: QualName::new(None, ns!(html), name),
            attrs: RefCell::new(Vec::new()),
            template_contents: RefCell::new(None),
            mathml_annotation_xml_integration_point: false,
        };
        ElementBuilder {
            element: Node::new(new_node_data),
        }
    }

    fn create_text_node(text: impl Into<StrTendril>) -> Handle {
        let new_node_data = NodeData::Text {
            contents: RefCell::new(text.into()),
        };
        Node::new(new_node_data)
    }
}
