use html5ever::serialize::{SerializeOpts, serialize};
use std::borrow::Cow;
use std::default::Default;
use std::env;
use std::ffi::OsStr;
use std::io::{self, BufWriter};
use std::path::{Path, PathBuf};

use markup5ever_rcdom::SerializableHandle;

mod anchor_permanence;
mod annotate_attributes;
mod boilerplate;
mod dom_utils;
mod interface_index;
mod io_utils;
mod parser;
mod rcdom_with_line_numbers;
mod represents;
mod self_link;
mod tag_omission;

#[tokio::main]
async fn main() -> io::Result<()> {
    let is_post = env::args().any(|a| a == "--singlepage-post");
    let result = if is_post {
        // --singlepage-post runs the postprocess phase, which is currently only meant to be used on the
        // singlepage output from Wattsi.
        run_postprocess().await
    } else {
        // By default we run the preprocess phase, which creates a new input for Wattsi.
        run_preprocess().await
    };

    // This gives slightly prettier error-printing.
    if let Err(e) = result {
        eprintln!("{e}");
        std::process::exit(1);
    }
    Ok(())
}

async fn run_preprocess() -> io::Result<()> {
    // Since we're using Rc in the DOM implementation, we must ensure that tasks
    // which act on it are confined to this thread.

    // Find the paths we need.
    let cache_dir = path_from_env("HTML_CACHE", ".cache");
    let source_dir = path_from_env("HTML_SOURCE", "../html");

    // Because parsing can jump around the tree a little, it's most reasonable
    // to just parse the whole document before doing any processing. Even for
    // the HTML standard, this doesn't take too long.
    let document = parser::parse_document_async(tokio::io::stdin()).await?;

    let mut boilerplate = boilerplate::Processor::new(cache_dir.clone(), source_dir.join("demos"));
    let mut represents = represents::Processor::new();
    let mut annotate_attributes = annotate_attributes::Processor::new();
    let mut tag_omission = tag_omission::Processor::new();
    let mut interface_index = interface_index::Processor::new();
    let mut self_link = self_link::Processor::new();

    // We do exactly one pass to identify the changes that need to be made.
    dom_utils::scan_dom(&document, &mut |h| {
        boilerplate.visit(h);
        represents.visit(h);
        annotate_attributes.visit(h);
        tag_omission.visit(h);
        interface_index.visit(h);
        self_link.visit(h);
    });

    // And then we apply all of the changes. These different processors mostly
    // apply quite local changes, so hopefully we never have to deal with
    // conflicts between them.
    boilerplate.apply().await?;
    represents.apply()?;
    annotate_attributes.apply().await?;
    tag_omission.apply()?;
    interface_index.apply()?;
    self_link.apply()?;

    // Finally, we write the result to standard out.
    let serializable: SerializableHandle = document.into();
    serialize(
        &mut BufWriter::with_capacity(128 * 1024, io::stdout()),
        &serializable,
        SerializeOpts::default(),
    )?;
    Ok(())
}

// The steps and considerations here are similar to run_preprocess.
async fn run_postprocess() -> io::Result<()> {
    let document = parser::parse_document_async(tokio::io::stdin()).await?;

    let mut anchor_permanence = anchor_permanence::Processor::new();

    dom_utils::scan_dom(&document, &mut |h| {
        anchor_permanence.visit(h);
    });

    anchor_permanence.apply()?;

    let serializable: SerializableHandle = document.into();
    serialize(
        &mut BufWriter::with_capacity(128 * 1024, io::stdout()),
        &serializable,
        SerializeOpts::default(),
    )?;
    Ok(())
}

fn path_from_env<'a, V, D>(var: &V, default: &'a D) -> Cow<'a, Path>
where
    V: AsRef<OsStr> + ?Sized,
    D: AsRef<Path> + ?Sized,
{
    match env::var_os(var) {
        Some(p) => PathBuf::from(p).into(),
        None => default.as_ref().into(),
    }
}
