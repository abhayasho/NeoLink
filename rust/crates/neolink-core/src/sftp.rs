//! The remote file browser's dealings with the system's `sftp` in batch mode: quoting names for its
//! command language and reading its long listings.

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RemoteEntry {
    pub name: String,
    pub is_directory: bool,
    pub is_link: bool,
    pub size: u64,
    /// The listing's date columns, as given ("Nov 16 21:08" or "Nov 16  2024").
    pub modified: String,
}

/// Quotes `text` as one argument of an sftp command.
pub fn quote(text: &str) -> String {
    format!("\"{}\"", text.replace('\\', "\\\\").replace('"', "\\\""))
}

/// A name that may be created or given in a rename: one path component.
pub fn valid_name(name: &str) -> bool {
    !name.trim().is_empty() && !name.contains('/') && !name.contains('\0') && !name.contains('\n') && name != "." && name != ".."
}

/// Joins a remote directory and a name.
pub fn join(directory: &str, name: &str) -> String {
    if directory.ends_with('/') {
        format!("{directory}{name}")
    } else {
        format!("{directory}/{name}")
    }
}

/// The directory above `path` ("/" is its own parent).
pub fn parent(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    match trimmed.rfind('/') {
        Some(0) | None => "/".to_string(),
        Some(index) => trimmed[..index].to_string(),
    }
}

/// Reads the output of `ls -lan`: one entry per long-format line; the command echo, "." and ".." and
/// anything else are skipped. Folders first, then names without regard to case, as the local tree.
pub fn parse_listing(output: &str) -> Vec<RemoteEntry> {
    let mut entries = Vec::new();
    for line in output.lines() {
        let kind = line.chars().next().unwrap_or(' ');
        if !matches!(kind, 'd' | '-' | 'l') || line.len() < 10 || !line[1..10].chars().all(|character| "rwxsStT-".contains(character)) {
            continue;
        }
        // Eight columns, then the name with its spaces.
        let mut rest = line;
        let mut fields = Vec::new();
        for _ in 0..8 {
            rest = rest.trim_start();
            let end = rest.find(char::is_whitespace).unwrap_or(rest.len());
            fields.push(&rest[..end]);
            rest = &rest[end..];
        }
        let name = rest.strip_prefix(' ').unwrap_or(rest).trim_start_matches(' ');
        if fields.len() < 8 || name.is_empty() || name == "." || name == ".." {
            continue;
        }
        entries.push(RemoteEntry { name: name.to_string(), is_directory: kind == 'd', is_link: kind == 'l', size: fields[4].parse().unwrap_or(0), modified: format!("{} {} {}", fields[5], fields[6], fields[7]) });
    }
    entries.sort_by(|a, b| b.is_directory.cmp(&a.is_directory).then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase())));
    entries
}

/// A size as the browser shows it.
pub fn size_label(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1000.0 && unit < UNITS.len() - 1 {
        value /= 1000.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} B")
    } else if value < 10.0 {
        format!("{value:.1} {}", UNITS[unit])
    } else {
        format!("{value:.0} {}", UNITS[unit])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn long_listings_become_entries() {
        let output = "sftp> ls -lan \"/srv/my files\"\n\
drwxr-xr-x    5 501      20            160 Nov 16 21:08 .\n\
drwxr-xr-x   18 501      20            576 Nov 16 21:12 ..\n\
-rw-r--r--    1 501      20        1273763 Nov 16 21:08 App Icon.png\n\
drwxr-xr-x    3 501      20             96 Nov 16  2024 editor\n\
lrwxr-xr-x    1 501      20             11 Nov 16 21:08 link\n\
-rw-r--r--    1 501      20           1344 Nov 16 21:08 Info.plist\n";
        let entries = parse_listing(output);
        assert_eq!(entries.iter().map(|entry| entry.name.as_str()).collect::<Vec<_>>(), vec!["editor", "App Icon.png", "Info.plist", "link"]);
        assert!(entries[0].is_directory && !entries[1].is_directory && entries[3].is_link);
        assert_eq!(entries[1].size, 1_273_763);
        assert_eq!(entries[0].modified, "Nov 16 2024");
    }

    #[test]
    fn names_are_quoted_and_paths_joined() {
        assert_eq!(quote("a \"b\" \\c"), "\"a \\\"b\\\" \\\\c\"");
        assert_eq!(join("/", "a"), "/a");
        assert_eq!(join("/srv/x", "a b"), "/srv/x/a b");
        assert_eq!(parent("/srv/x/"), "/srv");
        assert_eq!(parent("/srv"), "/");
        assert_eq!(parent("/"), "/");
        assert!(valid_name("a b.txt") && !valid_name("a/b") && !valid_name("..") && !valid_name(" "));
        assert_eq!(size_label(999), "999 B");
        assert_eq!(size_label(1_273_763), "1.3 MB");
        assert_eq!(size_label(45_000), "45 KB");
    }
}
