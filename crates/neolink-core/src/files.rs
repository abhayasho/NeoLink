//! File operations of the explorer, with the Swift app's rules (`LocalFileOperations`): copying always
//! picks a new name, and nothing existing is ever replaced.

use std::path::{Path, PathBuf};

/// A name a new or renamed item may have.
pub fn valid_name(name: &str) -> bool {
    !name.trim().is_empty() && !name.contains('/') && !name.contains('\0') && name != "." && name != ".." && (cfg!(not(windows)) || !name.contains('\\'))
}

pub const INVALID_NAME: &str = "Enter a name without slashes. A name cannot be just a dot or spaces.";
pub const EXISTING_NAME: &str = "An item with that name already exists. Choose another name.";
pub const COPY_INTO_ITSELF: &str = "A folder cannot be copied into itself or one of its subfolders.";

/// Where a copy of `source` goes inside `directory`: its own name, or "name copy", "name copy 2", ...
pub fn copy_destination(source: &Path, directory: &Path, exists: &dyn Fn(&Path) -> bool, is_directory: bool) -> PathBuf {
    let name = source.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    let (stem, suffix) = match name.rsplit_once('.') {
        Some((stem, extension)) if !is_directory && !stem.is_empty() && !extension.is_empty() => (stem.to_string(), format!(".{extension}")),
        _ => (name.clone(), String::new()),
    };
    let mut destination = directory.join(&name);
    let mut number = 1;
    while exists(&destination) {
        let copy = if number == 1 { " copy".to_string() } else { format!(" copy {number}") };
        destination = directory.join(format!("{stem}{copy}{suffix}"));
        number += 1;
    }
    destination
}

fn copy_tree(source: &Path, destination: &Path) -> std::io::Result<()> {
    if source.is_dir() {
        std::fs::create_dir(destination)?;
        for entry in std::fs::read_dir(source)? {
            let entry = entry?;
            copy_tree(&entry.path(), &destination.join(entry.file_name()))?;
        }
        Ok(())
    } else {
        // `create_new` so a file that appeared after the check is never overwritten.
        let mut input = std::fs::File::open(source)?;
        let mut output = std::fs::OpenOptions::new().write(true).create_new(true).open(destination)?;
        std::io::copy(&mut input, &mut output).map(|_| ())
    }
}

/// Copies `source` into `directory` under a new name if needed. Returns where it went.
pub fn copy_into(source: &Path, directory: &Path) -> Result<PathBuf, String> {
    let is_directory = source.is_dir();
    if is_directory {
        let (from, into) = (source.canonicalize().map_err(|error| error.to_string())?, directory.canonicalize().map_err(|error| error.to_string())?);
        if into.starts_with(&from) {
            return Err(COPY_INTO_ITSELF.into());
        }
    }
    let destination = copy_destination(source, directory, &|path| path.exists(), is_directory);
    copy_tree(source, &destination).map_err(|error| error.to_string())?;
    Ok(destination)
}

/// Renames `source` within its folder. Returns the new path (the old one if the name is unchanged).
pub fn rename(source: &Path, name: &str) -> Result<PathBuf, String> {
    if !valid_name(name) {
        return Err(INVALID_NAME.into());
    }
    let destination = source.parent().unwrap_or(Path::new("")).join(name);
    if destination == source {
        return Ok(destination);
    }
    if destination.exists() {
        return Err(EXISTING_NAME.into());
    }
    std::fs::rename(source, &destination).map_err(|error| error.to_string())?;
    Ok(destination)
}

/// Creates an empty file or a folder, never replacing anything.
pub fn create(directory: &Path, name: &str, is_directory: bool) -> Result<PathBuf, String> {
    if !valid_name(name) {
        return Err(INVALID_NAME.into());
    }
    let path = directory.join(name);
    let result = if is_directory { std::fs::create_dir(&path) } else { std::fs::OpenOptions::new().write(true).create_new(true).open(&path).map(|_| ()) };
    match result {
        Ok(()) => Ok(path),
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => Err(EXISTING_NAME.into()),
        Err(error) => Err(error.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let directory = std::env::temp_dir().join(format!("neolink-files-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).unwrap();
        directory
    }

    #[test]
    fn copies_get_numbered_names() {
        let taken = ["/d/a.txt", "/d/a copy.txt", "/d/folder"];
        let exists = |path: &Path| taken.contains(&path.to_string_lossy().replace('\\', "/").as_str());
        let directory = Path::new("/d");
        assert_eq!(copy_destination(Path::new("/x/b.txt"), directory, &exists, false), directory.join("b.txt"));
        assert_eq!(copy_destination(Path::new("/x/a.txt"), directory, &exists, false), directory.join("a copy 2.txt"));
        assert_eq!(copy_destination(Path::new("/x/folder"), directory, &exists, true), directory.join("folder copy"));
        assert_eq!(copy_destination(Path::new("/x/.env"), directory, &|path| path.ends_with(".env"), false), directory.join(".env copy"));
    }

    #[test]
    fn nothing_existing_is_replaced() {
        let directory = scratch("ops");
        let file = create(&directory, "a.txt", false).unwrap();
        std::fs::write(&file, "one").unwrap();
        assert_eq!(create(&directory, "a.txt", false), Err(EXISTING_NAME.to_string()));
        assert_eq!(create(&directory, "a/b", false), Err(INVALID_NAME.to_string()));
        let copy = copy_into(&file, &directory).unwrap();
        assert_eq!(copy.file_name().unwrap(), "a copy.txt");
        assert_eq!(std::fs::read_to_string(&copy).unwrap(), "one");
        assert_eq!(rename(&copy, "a.txt"), Err(EXISTING_NAME.to_string()));
        assert_eq!(rename(&copy, "b.txt").unwrap(), directory.join("b.txt"));
        let folder = create(&directory, "sub", true).unwrap();
        assert_eq!(copy_into(&folder, &folder), Err(COPY_INTO_ITSELF.to_string()));
        std::fs::write(folder.join("inner.txt"), "two").unwrap();
        let copied = copy_into(&folder, &directory).unwrap();
        assert_eq!(std::fs::read_to_string(copied.join("inner.txt")).unwrap(), "two");
        let _ = std::fs::remove_dir_all(&directory);
    }
}
