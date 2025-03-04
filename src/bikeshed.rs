//! Convert source to Bikeshed syntax.

use crate::dom_utils::NodeHandleExt;
use markup5ever_rcdom::Handle;

pub struct Processor {
}

impl Processor {
    pub fn new() -> Self {
        Processor {
        }
    }

    pub fn visit(&mut self, node: &Handle) {
        // Remove the <dl id="ref-list">
        if node.has_id("ref-list") {
            // node.remove_from_parent();
        }
    }
}
