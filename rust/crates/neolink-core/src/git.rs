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

    /// Files Git knows that are gone from the working tree.
    pub fn deleted(&self) -> Vec<&Path> {
        let mut paths: Vec<&Path> = self.statuses.iter().filter(|(_, status)| **status == Status::Deleted).map(|(path, _)| path.as_path()).collect();
        paths.sort();
        paths
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

/// One entry of `git status --porcelain=v1 -z` for the Source Control review (`GitChange`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Change {
    pub path: String,
    pub original: Option<String>,
    pub index: char,
    pub worktree: char,
}

impl Change {
    pub fn untracked(&self) -> bool {
        self.index == '?'
    }

    pub fn staged(&self) -> bool {
        self.index != ' ' && self.index != '?'
    }

    pub fn unstaged(&self) -> bool {
        self.worktree != ' '
    }

    /// A path Git may be given: relative, inside the repository.
    pub fn has_safe_paths(&self) -> bool {
        std::iter::once(&self.path).chain(self.original.iter()).all(|path| !path.is_empty() && !path.starts_with('/') && !path.contains('\0') && !path.split('/').any(|part| part == ".."))
    }
}

/// Parses `git status --porcelain=v1 -z --untracked-files=all`.
pub fn parse_changes(data: &[u8]) -> Vec<Change> {
    let records: Vec<&[u8]> = data.split(|byte| *byte == 0).collect();
    let mut result = Vec::new();
    let mut index = 0;
    while index < records.len() {
        let bytes = records[index];
        index += 1;
        if bytes.len() < 4 || bytes[2] != b' ' {
            continue;
        }
        let (staged, worktree) = (bytes[0] as char, bytes[1] as char);
        let mut original = None;
        if [staged, worktree].iter().any(|state| *state == 'R' || *state == 'C') {
            let Some(source) = records.get(index) else { break };
            original = Some(String::from_utf8_lossy(source).into_owned());
            index += 1;
        }
        result.push(Change { path: String::from_utf8_lossy(&bytes[3..]).into_owned(), original, index: staged, worktree });
    }
    result
}

/// A local branch name the review will pass to `git switch` (Git checks the rest).
pub fn plausible_branch_name(name: &str) -> bool {
    !name.is_empty() && !name.starts_with('-') && !name.contains('\0') && !name.contains("@{")
}

/// A full object id (SHA-1 or SHA-256), as stash identities must be.
pub fn valid_object_id(value: &str) -> bool {
    (value.len() == 40 || value.len() == 64) && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

#[cfg(test)]
mod review_tests {
    use super::*;

    #[test]
    fn status_records_become_changes() {
        let changes = parse_changes(b" M src/a.rs\0R  new name.rs\0old name.rs\0?? notes.txt\0MM both.rs\0");
        assert_eq!(changes.len(), 4);
        assert!(!changes[0].staged() && changes[0].unstaged());
        assert_eq!(changes[1].original.as_deref(), Some("old name.rs"));
        assert!(changes[1].staged() && !changes[1].unstaged());
        assert!(changes[2].untracked() && !changes[2].staged());
        assert!(changes[3].staged() && changes[3].unstaged());
    }

    #[test]
    fn unsafe_paths_and_names_are_refused() {
        let change = |path: &str| Change { path: path.into(), original: None, index: 'M', worktree: ' ' };
        assert!(change("src/a.rs").has_safe_paths());
        assert!(!change("/etc/passwd").has_safe_paths());
        assert!(!change("a/../../b").has_safe_paths());
        assert!(plausible_branch_name("feature/x") && !plausible_branch_name("-f") && !plausible_branch_name("a@{1}") && !plausible_branch_name(""));
        assert!(valid_object_id(&"a".repeat(40)) && !valid_object_id("abc") && !valid_object_id(&"g".repeat(40)));
    }
}
