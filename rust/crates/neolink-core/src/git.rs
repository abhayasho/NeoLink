//! Git status for the explorer's decorations, parsed from
//! `git status --porcelain=v1 -z --ignored=matching --untracked-files=normal` (docs/EXPLORER.md).
//! Running git is the caller's business; this is the parsing and the folder summaries.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// What a path's badge says, weakest first: a folder shows the strongest status beneath it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Status {
    Ignored,
    Renamed,
    Untracked,
    Added,
    Modified,
    Deleted,
    Conflict,
}

impl Status {
    /// The letter of the badge (docs/EXPLORER.md).
    pub fn letter(self) -> &'static str {
        match self {
            Status::Ignored => "",
            Status::Renamed => "R",
            Status::Untracked => "U",
            Status::Added => "A",
            Status::Modified => "M",
            Status::Deleted => "D",
            Status::Conflict => "!",
        }
    }
}

fn status_of(index: u8, tree: u8) -> Option<Status> {
    match (index, tree) {
        (b'!', b'!') => Some(Status::Ignored),
        (b'?', b'?') => Some(Status::Untracked),
        (b'U', _) | (_, b'U') | (b'A', b'A') | (b'D', b'D') => Some(Status::Conflict),
        (b'D', _) | (_, b'D') => Some(Status::Deleted),
        (b'R', _) | (_, b'R') => Some(Status::Renamed),
        (b'A', _) => Some(Status::Added),
        (b'M', _) | (_, b'M') | (b'T', _) | (_, b'T') => Some(Status::Modified),
        (b'C', _) => Some(Status::Added),
        _ => None,
    }
}

/// Parses NUL-separated porcelain v1 output into `(path relative to the repository root, status)`.
/// A trailing `/` (an untracked or ignored folder) is kept off the path and reported as `true`.
pub fn parse_porcelain(output: &[u8]) -> Vec<(PathBuf, Status, bool)> {
    let mut entries = Vec::new();
    let mut fields = output.split(|byte| *byte == 0).filter(|field| !field.is_empty());
    while let Some(field) = fields.next() {
        if field.len() < 4 || field[2] != b' ' {
            continue;
        }
        let (index, tree) = (field[0], field[1]);
        if index == b'R' || index == b'C' || tree == b'R' || tree == b'C' {
            // A rename or copy is followed by the path it came from.
            fields.next();
        }
        let Some(status) = status_of(index, tree) else { continue };
        let Ok(text) = std::str::from_utf8(&field[3..]) else { continue };
        let is_folder = text.ends_with('/');
        entries.push((PathBuf::from(text.trim_end_matches('/')), status, is_folder));
    }
    entries
}

/// Decorations for every path that has one, with folders summarising what is beneath them.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Decorations {
    statuses: HashMap<PathBuf, Status>,
    /// Folders that are ignored (or untracked) as a whole: everything inside shares the status.
    whole_folders: Vec<(PathBuf, Status)>,
}

impl Decorations {
    /// `root` is the repository's working tree; paths come back absolute.
    pub fn new(root: &Path, entries: &[(PathBuf, Status, bool)]) -> Decorations {
        let mut decorations = Decorations::default();
        for (relative, status, is_folder) in entries {
            let path = root.join(relative);
            if *is_folder {
                decorations.whole_folders.push((path.clone(), *status));
            }
            decorations.raise(path.clone(), *status);
            if *status == Status::Ignored {
                continue; // ignored files do not mark their folders
            }
            let mut ancestor = path.parent();
            while let Some(folder) = ancestor {
                if !folder.starts_with(root) || folder == root {
                    break;
                }
                // A folder holding a deletion is itself only modified.
                decorations.raise(folder.to_path_buf(), if *status == Status::Deleted { Status::Modified } else { *status });
                ancestor = folder.parent();
            }
        }
        decorations
    }

    fn raise(&mut self, path: PathBuf, status: Status) {
        let entry = self.statuses.entry(path).or_insert(status);
        if status > *entry {
            *entry = status;
        }
    }

    pub fn status(&self, path: &Path) -> Option<Status> {
        if let Some(status) = self.statuses.get(path) {
            return Some(*status);
        }
        self.whole_folders.iter().find(|(folder, _)| path.starts_with(folder)).map(|(_, status)| *status)
    }

    pub fn is_empty(&self) -> bool {
        self.statuses.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn porcelain_entries() {
        let output = b" M src/main.rs\0A  new.rs\0?? notes/\0!! target/\0D  gone.rs\0R  renamed.rs\0old name.rs\0UU both.rs\0MM twice.rs\0";
        let entries = parse_porcelain(output);
        let find = |name: &str| entries.iter().find(|entry| entry.0 == Path::new(name)).map(|entry| (entry.1, entry.2));
        assert_eq!(find("src/main.rs"), Some((Status::Modified, false)));
        assert_eq!(find("new.rs"), Some((Status::Added, false)));
        assert_eq!(find("notes"), Some((Status::Untracked, true)));
        assert_eq!(find("target"), Some((Status::Ignored, true)));
        assert_eq!(find("gone.rs"), Some((Status::Deleted, false)));
        assert_eq!(find("renamed.rs"), Some((Status::Renamed, false)));
        assert_eq!(find("old name.rs"), None, "the source of a rename is not an entry");
        assert_eq!(find("both.rs"), Some((Status::Conflict, false)));
        assert_eq!(find("twice.rs"), Some((Status::Modified, false)));
        assert_eq!(entries.len(), 8);
        assert!(parse_porcelain(b"").is_empty());
        assert!(parse_porcelain(b"garbage\0\0x\0").is_empty());
    }

    #[test]
    fn folders_summarise_and_ignored_folders_cover_their_contents() {
        let root = Path::new("/repo");
        let entries = parse_porcelain(b" M src/deep/a.rs\0?? src/new.rs\0UU src/deep/b.rs\0!! target/\0!! .env\0D  docs/old.md\0");
        let decorations = Decorations::new(root, &entries);
        assert_eq!(decorations.status(Path::new("/repo/src/deep/a.rs")), Some(Status::Modified));
        assert_eq!(decorations.status(Path::new("/repo/src/deep")), Some(Status::Conflict), "the strongest status beneath");
        assert_eq!(decorations.status(Path::new("/repo/src")), Some(Status::Conflict));
        assert_eq!(decorations.status(Path::new("/repo/docs")), Some(Status::Modified), "a deletion inside modifies the folder");
        assert_eq!(decorations.status(Path::new("/repo/target/debug/app")), Some(Status::Ignored));
        assert_eq!(decorations.status(Path::new("/repo/.env")), Some(Status::Ignored));
        assert_eq!(decorations.status(Path::new("/repo/README.md")), None);
        assert_eq!(decorations.status(Path::new("/repo")), None, "the root itself is not decorated");
    }
}
