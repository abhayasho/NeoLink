//! Paths as other programs name them.

use std::path::{Path, PathBuf};

/// Removes Windows' verbatim prefix (`\\?\C:\dir` to `C:\dir`, `\\?\UNC\server\share` to `\\server\share`).
/// `std::fs::canonicalize` adds it there; Neovim, shells and most tools name the same file without it,
/// so a path compared with theirs must not carry it.
pub fn without_verbatim_prefix(path: &str) -> String {
    if let Some(rest) = path.strip_prefix(r"\\?\UNC\") {
        return format!(r"\\{rest}");
    }
    if let Some(rest) = path.strip_prefix(r"\\?\") {
        let bytes = rest.as_bytes();
        if bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' {
            return rest.to_string();
        }
    }
    path.to_string()
}

/// The canonical form of `path` (symbolic links resolved) in the spelling other programs use. A path
/// that does not exist is returned unchanged.
pub fn canonical(path: &Path) -> PathBuf {
    match path.canonicalize() {
        Ok(resolved) => match resolved.to_str() {
            Some(text) => PathBuf::from(without_verbatim_prefix(text)),
            None => resolved,
        },
        Err(_) => path.to_path_buf(),
    }
}

/// The user's home folder (`HOME`; `USERPROFILE` on Windows).
pub fn home() -> Option<PathBuf> {
    std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).filter(|home| !home.is_empty()).map(PathBuf::from)
}

/// `path` for display, with the home folder written `~` (`~/Projects/app`, or `~` itself).
pub fn tilde(path: &Path) -> String {
    tilde_in(path, home().as_deref())
}

fn tilde_in(path: &Path, home: Option<&Path>) -> String {
    match home.and_then(|home| path.strip_prefix(home).ok()) {
        Some(rest) if rest.as_os_str().is_empty() => "~".into(),
        Some(rest) => format!("~{}{}", std::path::MAIN_SEPARATOR, rest.display()),
        None => path.display().to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn home_is_written_as_a_tilde() {
        let home = Path::new("/Users/me");
        let separator = std::path::MAIN_SEPARATOR;
        assert_eq!(tilde_in(Path::new("/Users/me"), Some(home)), "~");
        assert_eq!(tilde_in(&home.join("Projects").join("app"), Some(home)), format!("~{separator}Projects{separator}app"));
        // A folder that only starts with the same letters is not inside home.
        assert_eq!(tilde_in(Path::new("/Users/meg/app"), Some(home)), "/Users/meg/app");
        assert_eq!(tilde_in(Path::new("/tmp/x"), None), "/tmp/x");
    }

    #[test]
    fn verbatim_prefixes_are_removed_only_where_they_mean_nothing() {
        assert_eq!(without_verbatim_prefix(r"\\?\C:\Users\me\a.txt"), r"C:\Users\me\a.txt");
        assert_eq!(without_verbatim_prefix(r"\\?\UNC\server\share\a.txt"), r"\\server\share\a.txt");
        assert_eq!(without_verbatim_prefix(r"C:\Users\me\a.txt"), r"C:\Users\me\a.txt");
        assert_eq!(without_verbatim_prefix("/home/me/a.txt"), "/home/me/a.txt");
        // A verbatim path that is not a drive or a share is left alone.
        assert_eq!(without_verbatim_prefix(r"\\?\Volume{1234}\a.txt"), r"\\?\Volume{1234}\a.txt");
    }

    #[test]
    fn canonical_resolves_existing_paths_and_keeps_missing_ones() {
        let directory = std::env::temp_dir();
        let resolved = canonical(&directory);
        assert!(resolved.is_absolute());
        assert!(!resolved.to_string_lossy().starts_with(r"\\?\"));
        let missing = directory.join("neolink-does-not-exist-7f3a");
        assert_eq!(canonical(&missing), missing);
    }
}
