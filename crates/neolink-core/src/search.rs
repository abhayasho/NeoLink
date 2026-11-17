//! Quick Open's file matching, with the rules of the Swift app's `ProjectSearch`.

/// Folders never indexed or searched.
pub const EXCLUDED: [&str; 13] = [".git", "node_modules", ".build", "build", "dist", ".venv", "venv", "__pycache__", "DerivedData", ".next", "vendor", "Pods", "target"];
/// Files listed at most.
pub const MAX_FILES: usize = 50_000;
/// Results shown at most (file names; text matches).
pub const MAX_SHOWN: usize = 100;
pub const MAX_MATCHES: usize = 200;

/// The arguments every ripgrep call gets.
pub fn rg_arguments() -> Vec<String> {
    let mut arguments: Vec<String> = ["--no-config", "--threads", "2", "--hidden", "--no-messages"].iter().map(|text| text.to_string()).collect();
    for folder in EXCLUDED {
        arguments.push("--glob".into());
        arguments.push(format!("!**/{folder}/**"));
    }
    arguments
}

/// Subsequence matching that rewards contiguous runs, file-name starts and path boundaries.
/// Both arguments are expected in lower case.
pub fn fuzzy_score(query: &str, path: &str) -> Option<i64> {
    let needle: Vec<char> = query.chars().collect();
    let haystack: Vec<char> = path.chars().collect();
    if needle.is_empty() {
        return Some(0);
    }
    let (mut position, mut previous, mut score) = (0usize, -2i64, 0i64);
    for character in &needle {
        let next = position + haystack[position.min(haystack.len())..].iter().position(|other| other == character)?;
        score += if next as i64 == previous + 1 { 18 } else { 1 };
        if next == 0 || "/._- ".contains(haystack[next - 1]) {
            score += 12;
        }
        score -= (next - position) as i64;
        previous = next as i64;
        position = next + 1;
    }
    let name = path.rsplit('/').next().unwrap_or(path);
    if name == query {
        score += 200;
    } else if name.starts_with(query) {
        score += 100;
    } else if name.contains(query) {
        score += 50;
    }
    Some(score - (haystack.len() as i64 - needle.len() as i64).min(100))
}

/// The best `MAX_SHOWN` files for `query` (space-separated terms, all of which must match), best first.
/// `cancelled` is polled so a newer query can stop this one.
pub fn filter(files: &[String], query: &str, cancelled: &dyn Fn() -> bool) -> Vec<String> {
    let query: String = query.chars().take(256).collect::<String>().to_lowercase();
    let terms: Vec<&str> = query.split_whitespace().take(16).collect();
    if terms.is_empty() {
        return files.iter().take(MAX_SHOWN).cloned().collect();
    }
    let mut scored: Vec<(&String, i64)> = Vec::new();
    for (index, path) in files.iter().enumerate() {
        if index % 1024 == 0 && cancelled() {
            return Vec::new();
        }
        let value = path.to_lowercase();
        let mut total = 0;
        let mut matched = true;
        for term in &terms {
            match fuzzy_score(term, &value) {
                Some(score) => total += score,
                None => {
                    matched = false;
                    break;
                }
            }
        }
        if matched {
            scored.push((path, total));
        }
    }
    scored.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(b.0)));
    scored.into_iter().take(MAX_SHOWN).map(|(path, _)| path.clone()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_names_beat_prefixes_beat_substrings() {
        let exact = fuzzy_score("main.rs", "src/main.rs").unwrap();
        let prefix = fuzzy_score("main", "src/main.rs").unwrap();
        let inside = fuzzy_score("ain", "src/main.rs").unwrap();
        assert!(exact > prefix && prefix > inside);
        assert_eq!(fuzzy_score("xyz", "src/main.rs"), None);
        assert_eq!(fuzzy_score("", "anything"), Some(0));
    }

    #[test]
    fn every_term_must_match_and_ties_sort_by_path() {
        let files: Vec<String> = ["src/tree.rs", "src/term.rs", "docs/tree.md", "README.md"].iter().map(|text| text.to_string()).collect();
        let never = || false;
        assert_eq!(filter(&files, "tree rs", &never), vec!["src/tree.rs"]);
        assert_eq!(filter(&files, "", &never).len(), 4);
        // The shorter path loses less for its length.
        assert_eq!(filter(&files, "TREE", &never), vec!["src/tree.rs", "docs/tree.md"]);
        assert!(filter(&files, "zzz", &never).is_empty());
        assert!(filter(&files, "tree", &|| true).is_empty());
    }

    #[test]
    fn excluded_folders_become_globs() {
        let arguments = rg_arguments();
        assert!(arguments.contains(&"!**/node_modules/**".to_string()));
        assert_eq!(arguments.len(), 5 + 2 * EXCLUDED.len());
    }
}
