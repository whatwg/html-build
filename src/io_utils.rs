//! Misccellaneous utilities for I/O.

use std::io;
use std::path::Path;

use html5ever::tendril::{self, SendTendril, StrTendril};
use tokio::task::JoinHandle;

type SendStrTendril = SendTendril<tendril::fmt::UTF8>;

/// Check that a path is safe to open, even if the source is potentially untrusted.
pub fn is_safe_path(path: impl AsRef<Path>) -> bool {
    use std::path::Component;
    path.as_ref()
        .components()
        .all(|c| matches!(c, Component::Normal(_) | Component::CurDir))
}

/// In a spawned task, read to a string, then move it to a tendril.
pub fn read_to_str_tendril(path: impl AsRef<Path>) -> JoinHandle<io::Result<SendStrTendril>> {
    let path = path.as_ref().to_owned();
    tokio::spawn(async move {
        let string = tokio::fs::read_to_string(path).await?;
        Ok(StrTendril::from(string).into_send())
    })
}

/// Creates a join Handle for an error. Useful when an operation will fail, but
/// it's more convenient to handle later on.
pub fn async_error<R: Send + 'static>(err: io::Error) -> JoinHandle<io::Result<R>> {
    tokio::spawn(async move { Err(err) })
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn test_is_safe_path() {
        assert!(is_safe_path("a.txt"));
        assert!(is_safe_path("a/b.txt"));
        assert!(is_safe_path("a/b/c/./d.txt"));
        assert!(!is_safe_path("../parent.txt"));
        assert!(!is_safe_path("/etc/passwd"));
    }

    #[tokio::test]
    async fn test_read_to_str_tendril() -> io::Result<()> {
        let temp_dir = TempDir::new()?;
        let file_path = temp_dir.path().join("a.txt");
        tokio::fs::write(&file_path, "Hello, world!").await?;
        let send_tendril = read_to_str_tendril(&file_path).await??;
        assert_eq!(StrTendril::from(send_tendril).as_ref(), "Hello, world!");
        Ok(())
    }
}