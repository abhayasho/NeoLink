//! The project tree behind the explorer: which folders are open, what is in them, and the flat list of
//! rows that results. Directory contents are supplied from outside (they are read on another thread);
//! nothing here touches the file system.
//!
//! Behaviour follows docs/EXPLORER.md: folders before files, case-insensitive order, hidden files off by
//! default, an expanded chain of single-child folders shown as one row (`src/main/java`), collapsed
//! subtrees never traversed, and bounds on rows and entries.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

/// Rows shown at most; the footer says when the limit was hit.
pub const MAX_ROWS: usize = 5_000;
/// Entries kept per directory.
pub const MAX_ENTRIES: usize = 10_000;
/// Levels a compact chain may fold into one row.
pub const MAX_CHAIN: usize = 16;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub name: String,
    pub is_directory: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RowKind {
    File,
    Folder { expanded: bool, loading: bool },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Row {
    /// For a compact chain, the deepest folder (the one that opens and closes).
    pub path: PathBuf,
    /// The name, or `a/b/c` for a compact chain.
    pub label: String,
    pub depth: usize,
    pub kind: RowKind,
}

pub struct Tree {
    root: PathBuf,
    expanded: HashSet<PathBuf>,
    listings: HashMap<PathBuf, Vec<Entry>>,
    pub show_hidden: bool,
    pub compact: bool,
    /// Whether the last `rows()` call stopped at `MAX_ROWS`.
    truncated: bool,
}

fn is_hidden(name: &str) -> bool {
    name.starts_with('.')
}

impl Tree {
    pub fn new(root: PathBuf) -> Tree {
        let mut expanded = HashSet::new();
        expanded.insert(root.clone());
        Tree { root, expanded, listings: HashMap::new(), show_hidden: false, compact: true, truncated: false }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn was_truncated(&self) -> bool {
        self.truncated
    }

    /// The contents of `directory`, as read from disk. Sorted and bounded here.
    pub fn set_listing(&mut self, directory: &Path, mut entries: Vec<Entry>) {
        entries.sort_by(|a, b| b.is_directory.cmp(&a.is_directory).then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase())).then_with(|| a.name.cmp(&b.name)));
        entries.truncate(MAX_ENTRIES);
        self.listings.insert(directory.to_path_buf(), entries);
    }

    /// Forgets a listing (the directory changed on disk); it will be asked for again while expanded.
    pub fn invalidate(&mut self, directory: &Path) {
        self.listings.remove(directory);
    }

    pub fn is_expanded(&self, directory: &Path) -> bool {
        self.expanded.contains(directory)
    }

    /// Opens or closes a folder. Closing keeps the listings of what was inside.
    pub fn toggle(&mut self, directory: &Path) {
        if directory == self.root {
            return;
        }
        if !self.expanded.remove(directory) {
            self.expanded.insert(directory.to_path_buf());
        }
    }

    pub fn collapse_all(&mut self) {
        self.expanded.clear();
        self.expanded.insert(self.root.clone());
    }

    /// Opens every folder between the root and `path`, so its row exists once the listings are in.
    /// Returns `false` if `path` is not inside the root.
    pub fn reveal(&mut self, path: &Path) -> bool {
        if !path.starts_with(&self.root) {
            return false;
        }
        let mut ancestor = path.parent();
        while let Some(directory) = ancestor {
            if !directory.starts_with(&self.root) {
                break;
            }
            self.expanded.insert(directory.to_path_buf());
            if directory == self.root {
                break;
            }
            ancestor = directory.parent();
        }
        true
    }

    /// Expanded folders whose contents are not known yet, shallowest first.
    pub fn wanted(&self) -> Vec<PathBuf> {
        let mut wanted = Vec::new();
        let mut stack = vec![self.root.clone()];
        while let Some(directory) = stack.pop() {
            if !self.expanded.contains(&directory) {
                continue;
            }
            match self.listings.get(&directory) {
                None => wanted.push(directory),
                Some(entries) => {
                    for entry in entries.iter().filter(|entry| entry.is_directory) {
                        stack.push(directory.join(&entry.name));
                    }
                }
            }
        }
        wanted.sort_by_key(|path| path.components().count());
        wanted
    }

    fn visible<'a>(&self, entries: &'a [Entry]) -> impl Iterator<Item = &'a Entry> {
        let show_hidden = self.show_hidden;
        entries.iter().filter(move |entry| show_hidden || !is_hidden(&entry.name))
    }

    /// The rows to show, top to bottom.
    pub fn rows(&mut self) -> Vec<Row> {
        let mut rows = Vec::new();
        self.truncated = false;
        self.append(&self.root.clone(), 0, &mut rows);
        rows
    }

    fn append(&mut self, directory: &Path, depth: usize, rows: &mut Vec<Row>) {
        let Some(entries) = self.listings.get(directory).cloned() else { return };
        for entry in self.visible(&entries) {
            if rows.len() >= MAX_ROWS {
                self.truncated = true;
                return;
            }
            let mut path = directory.join(&entry.name);
            if !entry.is_directory {
                rows.push(Row { path, label: entry.name.clone(), depth, kind: RowKind::File });
                continue;
            }
            let mut label = entry.name.clone();
            // An open folder whose only visible entry is a folder shares its row with it.
            if self.compact {
                let mut levels = 1;
                while levels < MAX_CHAIN && self.expanded.contains(&path) {
                    let Some(inner) = self.listings.get(&path) else { break };
                    let mut visible = self.visible(inner);
                    let (Some(only), None) = (visible.next(), visible.next()) else { break };
                    if !only.is_directory {
                        break;
                    }
                    label.push('/');
                    label.push_str(&only.name);
                    path = path.join(&only.name);
                    levels += 1;
                }
            }
            let expanded = self.expanded.contains(&path);
            let loading = expanded && !self.listings.contains_key(&path);
            rows.push(Row { path: path.clone(), label, depth, kind: RowKind::Folder { expanded, loading } });
            if expanded {
                self.append(&path, depth + 1, rows);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn folder(name: &str) -> Entry {
        Entry { name: name.into(), is_directory: true }
    }

    fn file(name: &str) -> Entry {
        Entry { name: name.into(), is_directory: false }
    }

    fn labels(tree: &mut Tree) -> Vec<String> {
        tree.rows().iter().map(|row| format!("{}{}", "  ".repeat(row.depth), row.label)).collect()
    }

    fn project() -> Tree {
        let mut tree = Tree::new(PathBuf::from("/p"));
        tree.set_listing(Path::new("/p"), vec![file("b.txt"), folder("src"), file("A.md"), file(".env"), folder("Docs"), folder(".git")]);
        tree
    }

    #[test]
    fn folders_first_case_insensitive_hidden_off() {
        let mut tree = project();
        assert_eq!(labels(&mut tree), ["Docs", "src", "A.md", "b.txt"]);
        tree.show_hidden = true;
        assert_eq!(labels(&mut tree), [".git", "Docs", "src", ".env", "A.md", "b.txt"]);
    }

    #[test]
    fn expanding_asks_for_the_listing_and_shows_children_in_place() {
        let mut tree = project();
        assert!(tree.wanted().is_empty());
        tree.toggle(Path::new("/p/src"));
        assert_eq!(tree.wanted(), [PathBuf::from("/p/src")]);
        assert!(matches!(tree.rows()[1].kind, RowKind::Folder { expanded: true, loading: true }));
        tree.set_listing(Path::new("/p/src"), vec![file("main.rs"), folder("util")]);
        assert_eq!(labels(&mut tree), ["Docs", "src", "  util", "  main.rs", "A.md", "b.txt"]);
        assert!(tree.wanted().is_empty(), "a collapsed subtree is not traversed");
        tree.toggle(Path::new("/p/src"));
        assert_eq!(labels(&mut tree), ["Docs", "src", "A.md", "b.txt"]);
        // Reopening shows the kept listing at once.
        tree.toggle(Path::new("/p/src"));
        assert_eq!(labels(&mut tree).len(), 6);
    }

    #[test]
    fn single_child_chains_compact_into_one_row() {
        let mut tree = Tree::new(PathBuf::from("/p"));
        tree.set_listing(Path::new("/p"), vec![folder("src")]);
        tree.toggle(Path::new("/p/src"));
        tree.set_listing(Path::new("/p/src"), vec![folder("main")]);
        tree.toggle(Path::new("/p/src/main"));
        tree.set_listing(Path::new("/p/src/main"), vec![folder("java"), file(".keep")]);
        // The chain's last folder is closed: one row, opening it shows what is inside.
        let rows = tree.rows();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].label, "src/main/java");
        assert_eq!(rows[0].path, PathBuf::from("/p/src/main/java"));
        assert!(matches!(rows[0].kind, RowKind::Folder { expanded: false, .. }));
        tree.toggle(&rows[0].path);
        tree.set_listing(Path::new("/p/src/main/java"), vec![file("App.java"), file("Util.java")]);
        assert_eq!(labels(&mut tree), ["src/main/java", "  App.java", "  Util.java"]);
        tree.compact = false;
        assert_eq!(labels(&mut tree), ["src", "  main", "    java", "      App.java", "      Util.java"]);
    }

    #[test]
    fn reveal_opens_the_ancestors_of_a_file() {
        let mut tree = project();
        assert!(tree.reveal(Path::new("/p/src/util/deep/file.rs")));
        assert_eq!(tree.wanted(), [PathBuf::from("/p/src")]);
        tree.set_listing(Path::new("/p/src"), vec![folder("util"), file("main.rs")]);
        assert_eq!(tree.wanted(), [PathBuf::from("/p/src/util")]);
        assert!(!tree.reveal(Path::new("/elsewhere/file.rs")), "a file outside the root does not replace it");
    }

    #[test]
    fn rows_are_bounded() {
        let mut tree = Tree::new(PathBuf::from("/p"));
        tree.set_listing(Path::new("/p"), (0..MAX_ROWS + 50).map(|i| file(&format!("f{i:05}"))).collect());
        assert_eq!(tree.rows().len(), MAX_ROWS);
        assert!(tree.was_truncated());
        tree.collapse_all();
        assert!(tree.is_expanded(Path::new("/p")), "the root stays open");
    }
}
