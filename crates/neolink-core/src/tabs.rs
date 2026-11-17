//! Tab titles (the Swift app's `TabPresentation`): files with the same name show the shortest part of
//! their folder that tells them apart.

/// For each tab, the folder context shown after its title: empty unless another tab has the same title.
/// `paths[i]` is `None` for tabs that are not files.
pub fn contexts(titles: &[String], paths: &[Option<String>]) -> Vec<String> {
    let folders = |path: &str| -> Vec<String> {
        let normalized = path.replace('\\', "/");
        let mut parts: Vec<String> = normalized.split('/').filter(|part| !part.is_empty()).map(str::to_string).collect();
        parts.pop();
        parts
    };
    let suffix = |parts: &[String], depth: usize| parts[parts.len().saturating_sub(depth)..].join("/");
    (0..titles.len())
        .map(|index| {
            let peers: Vec<usize> = (0..titles.len()).filter(|other| *other != index && titles[*other] == titles[index]).collect();
            let Some(path) = paths[index].as_deref().filter(|_| !peers.is_empty()) else { return String::new() };
            let components = folders(path);
            let mut context = String::new();
            for depth in 1..=components.len().max(1) {
                context = suffix(&components, depth);
                let distinct = peers.iter().all(|other| match paths[*other].as_deref() {
                    Some(other_path) => suffix(&folders(other_path), depth) != context,
                    None => true,
                });
                if distinct {
                    break;
                }
            }
            context
        })
        .collect()
}

/// How far a strip must be scrolled so the span `start..end` is inside a viewport `width` wide that
/// currently begins at `scroll`: only as far as the nearest edge.
pub fn reveal(scroll: f32, width: f32, start: f32, end: f32) -> f32 {
    if start < scroll {
        start
    } else if end > scroll + width {
        end - width
    } else {
        scroll
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| value.to_string()).collect()
    }

    #[test]
    fn duplicate_names_get_the_shortest_distinct_folder() {
        let titles = strings(&["mod.rs", "mod.rs", "main.rs", "shell", "mod.rs"]);
        let paths = vec![Some("/p/a/x/mod.rs".to_string()), Some("/p/b/x/mod.rs".to_string()), Some("/p/main.rs".to_string()), None, Some("/p/c/mod.rs".to_string())];
        assert_eq!(contexts(&titles, &paths), strings(&["a/x", "b/x", "", "", "c"]));
    }

    #[test]
    fn a_terminal_with_the_same_title_needs_no_folder() {
        let titles = strings(&["notes", "notes"]);
        assert_eq!(contexts(&titles, &[Some("/p/notes".to_string()), None]), strings(&["p", ""]));
    }

    #[test]
    fn revealing_moves_only_to_the_nearest_edge() {
        assert_eq!(reveal(100.0, 300.0, 150.0, 250.0), 100.0);
        assert_eq!(reveal(100.0, 300.0, 40.0, 160.0), 40.0);
        assert_eq!(reveal(100.0, 300.0, 350.0, 470.0), 170.0);
    }
}
