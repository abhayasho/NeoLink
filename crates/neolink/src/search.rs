//! Quick Open and Find in Files (the Swift app's `ProjectSearchSheet`): the same ripgrep calls, limits
//! and texts. The work runs on its own thread; the newest query wins.

use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, RecvTimeoutError, Sender};
use std::sync::{Arc, Weak};
use std::time::Duration;

use neolink_core::search::{self, MAX_FILES, MAX_MATCHES};
use parking_lot::Mutex;
use winit::keyboard::{Key, NamedKey};

use crate::chrome::{faded, Ui};
use crate::frame::Shared;
use crate::icons::IconWeight;
use crate::render::Rect;
use crate::theme;

#[derive(Clone, Debug, PartialEq)]
pub struct Match {
    pub path: String,
    pub line: Option<u64>,
    pub preview: String,
}

#[derive(Default)]
struct Results {
    matches: Vec<Match>,
    files: usize,
    loading: bool,
    error: Option<String>,
    /// Which query the matches answer.
    query: String,
    revision: u64,
}

pub struct SearchSheet {
    pub contents: bool,
    root: PathBuf,
    query: String,
    results: Arc<Mutex<Results>>,
    queries: Sender<String>,
    selected: usize,
    scroll: f32,
    rows: Vec<Rect>,
    list: Rect,
    frame: Rect,
    done: Rect,
}

pub enum Outcome {
    Stay,
    Close,
    Open(PathBuf, Option<u64>),
}

/// `rg`, from PATH or the usual install places (a program started from the Finder has a short PATH).
fn ripgrep() -> Option<PathBuf> {
    let name = if cfg!(windows) { "rg.exe" } else { "rg" };
    let from_path = std::env::var_os("PATH").into_iter().flat_map(|paths| std::env::split_paths(&paths).collect::<Vec<_>>());
    from_path.chain(["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].iter().map(PathBuf::from)).map(|directory| directory.join(name)).find(|candidate| candidate.is_file())
}

const MISSING_TOOL: &str = "Project search needs ripgrep. Install it with brew install ripgrep.";
const FAILED: &str = "Search could not finish. Check folder access or try a smaller project.";

fn list_files(root: &Path) -> Result<Vec<String>, String> {
    let rg = ripgrep().ok_or(MISSING_TOOL)?;
    let output = std::process::Command::new(rg).args(["--files", "-0"]).args(search::rg_arguments()).args(["--", "."]).current_dir(root).stdin(std::process::Stdio::null()).output().map_err(|_| FAILED.to_string())?;
    if !matches!(output.status.code(), Some(0) | Some(1)) {
        return Err(FAILED.into());
    }
    let mut files: Vec<String> = output.stdout.split(|byte| *byte == 0).filter(|path| !path.is_empty()).take(MAX_FILES).map(|path| {
        let path = String::from_utf8_lossy(path).replace('\\', "/");
        path.strip_prefix("./").map(str::to_string).unwrap_or(path)
    }).collect();
    files.sort();
    Ok(files)
}

/// Parses `rg --json` output into at most `MAX_MATCHES` matches.
pub fn parse_matches(output: &[u8]) -> Vec<Match> {
    let mut matches = Vec::new();
    for line in output.split(|byte| *byte == b'\n') {
        let Ok(json) = serde_json::from_slice::<serde_json::Value>(line) else { continue };
        if json["type"] != "match" {
            continue;
        }
        let data = &json["data"];
        let (Some(path), Some(number), Some(content)) = (data["path"]["text"].as_str(), data["line_number"].as_u64(), data["lines"]["text"].as_str()) else { continue };
        let path = path.replace('\\', "/");
        matches.push(Match { path: path.strip_prefix("./").map(str::to_string).unwrap_or(path), line: Some(number), preview: content.trim().chars().take(250).collect() });
        if matches.len() == MAX_MATCHES {
            break;
        }
    }
    matches
}

fn find_text(root: &Path, query: &str) -> Result<Vec<Match>, String> {
    if query.is_empty() {
        return Ok(Vec::new());
    }
    let rg = ripgrep().ok_or(MISSING_TOOL)?;
    let output = std::process::Command::new(rg).args(["--json", "--fixed-strings", "--smart-case", "--max-count", "20", "--max-filesize", "2M"]).args(search::rg_arguments()).args(["--", query, "."]).current_dir(root).stdin(std::process::Stdio::null()).output().map_err(|_| FAILED.to_string())?;
    if !matches!(output.status.code(), Some(0) | Some(1)) {
        return Err(FAILED.into());
    }
    Ok(parse_matches(&output.stdout))
}

impl SearchSheet {
    pub fn new(root: &Path, contents: bool, shared: Weak<Shared>) -> SearchSheet {
        let results = Arc::new(Mutex::new(Results { loading: !contents, ..Results::default() }));
        let (queries, incoming) = channel::<String>();
        let (worker_results, worker_root) = (results.clone(), root.to_path_buf());
        let _ = std::thread::Builder::new().name("search".into()).spawn(move || {
            let publish = |change: &dyn Fn(&mut Results)| {
                let mut results = worker_results.lock();
                change(&mut results);
                results.revision += 1;
                drop(results);
                if let Some(shared) = shared.upgrade() {
                    shared.invalidate();
                }
            };
            let mut files: Vec<String> = Vec::new();
            let mut query = String::new();
            if !contents {
                match list_files(&worker_root) {
                    Ok(listed) => files = listed,
                    Err(error) => publish(&|results| results.error = Some(error.clone())),
                }
            }
            let mut pending = true;
            loop {
                // The newest query wins; text searches wait 180 ms for typing to pause.
                loop {
                    let next = if pending && !contents { incoming.try_recv().map_err(|_| RecvTimeoutError::Timeout) } else if pending { incoming.recv_timeout(Duration::from_millis(180)) } else { incoming.recv().map_err(|_| RecvTimeoutError::Disconnected) };
                    match next {
                        Ok(newer) => {
                            query = newer;
                            pending = true;
                        }
                        Err(RecvTimeoutError::Timeout) => break,
                        Err(RecvTimeoutError::Disconnected) => return,
                    }
                }
                pending = false;
                let asked = query.clone();
                if contents {
                    publish(&|results| {
                        results.loading = true;
                        results.error = None;
                    });
                    let found = find_text(&worker_root, &asked);
                    publish(&|results| {
                        results.loading = false;
                        results.query = asked.clone();
                        match &found {
                            Ok(matches) => results.matches = matches.clone(),
                            Err(error) => results.error = Some(error.clone()),
                        }
                    });
                } else {
                    let matches: Vec<Match> = search::filter(&files, &asked, &|| false).into_iter().map(|path| Match { path, line: None, preview: String::new() }).collect();
                    publish(&|results| {
                        results.loading = false;
                        results.files = files.len();
                        results.query = asked.clone();
                        results.matches = matches.clone();
                    });
                }
            }
        });
        SearchSheet { contents, root: root.to_path_buf(), query: String::new(), results, queries, selected: 0, scroll: 0.0, rows: Vec::new(), list: Rect::default(), frame: Rect::default(), done: Rect::default() }
    }

    fn query_changed(&mut self) {
        self.selected = 0;
        self.scroll = 0.0;
        let _ = self.queries.send(self.query.clone());
    }

    fn chosen(&self, index: usize) -> Outcome {
        match self.results.lock().matches.get(index) {
            Some(found) => Outcome::Open(self.root.join(&found.path), found.line),
            None => Outcome::Stay,
        }
    }

    pub fn key(&mut self, key: &Key, text: Option<&str>) -> Outcome {
        let count = self.results.lock().matches.len();
        match key {
            Key::Named(NamedKey::Escape) => return Outcome::Close,
            Key::Named(NamedKey::Enter) => return self.chosen(self.selected),
            Key::Named(NamedKey::ArrowDown) => self.selected = (self.selected + 1).min(count.saturating_sub(1)),
            Key::Named(NamedKey::ArrowUp) => self.selected = self.selected.saturating_sub(1),
            Key::Named(NamedKey::Backspace) => {
                if self.query.pop().is_some() {
                    self.query_changed();
                }
            }
            _ => {
                if let Some(text) = text.filter(|text| !text.chars().any(char::is_control)) {
                    self.query.push_str(text);
                    self.query_changed();
                }
            }
        }
        self.reveal_selected();
        Outcome::Stay
    }

    fn reveal_selected(&mut self) {
        if let Some(row) = self.rows.get(self.selected) {
            if row.y < self.list.y {
                self.scroll -= self.list.y - row.y;
            } else if row.bottom() > self.list.bottom() {
                self.scroll += row.bottom() - self.list.bottom();
            }
        } else if self.selected == 0 {
            self.scroll = 0.0;
        }
    }

    pub fn click(&mut self, x: f32, y: f32) -> Outcome {
        if self.done.contains(x, y) || !self.frame.contains(x, y) {
            return Outcome::Close;
        }
        if self.list.contains(x, y) {
            if let Some(index) = self.rows.iter().position(|row| row.contains(x, y)) {
                return self.chosen(index);
            }
        }
        Outcome::Stay
    }

    pub fn pointer(&mut self, x: f32, y: f32) -> bool {
        if !self.list.contains(x, y) {
            return false;
        }
        match self.rows.iter().position(|row| row.contains(x, y)) {
            Some(index) if index != self.selected => {
                self.selected = index;
                true
            }
            _ => false,
        }
    }

    /// Scrolls the results by `delta` pixels (positive: content moves down).
    pub fn scroll(&mut self, delta: f32) {
        self.scroll -= delta;
    }

    pub fn signature(&self) -> u64 {
        let results = self.results.lock();
        let mut value = results.revision.wrapping_mul(0x9E3779B97F4A7C15) ^ (self.selected as u64).rotate_left(20) ^ (self.scroll.to_bits() as u64).rotate_left(40) ^ self.contents as u64;
        for byte in self.query.bytes() {
            value = (value.rotate_left(7) ^ byte as u64).wrapping_mul(0x100000001B3);
        }
        value
    }

    pub fn draw(&mut self, ui: &mut Ui, window: (f32, f32)) {
        let results = self.results.lock();
        ui.fill(Rect::new(0.0, 0.0, window.0, window.1), [0, 0, 0, 90]);
        let pad = ui.px(20.0);
        let width = ui.px(630.0).min(window.0 - ui.px(40.0));
        let list_height = ui.px(340.0).min(window.1 - ui.px(260.0)).max(ui.px(80.0));
        let error_height = if results.error.is_some() { ui.px(16.0 + 12.0) } else { 0.0 };
        let height = pad + ui.px(22.0 + 12.0 + 24.0 + 12.0) + error_height + list_height + ui.px(10.0 + 1.0 + 10.0 + 13.0) + pad;
        let frame = Rect::new(((window.0 - width) * 0.5).round(), ui.px(60.0), width, height);
        self.frame = frame;
        ui.shadow(frame, 10.0);
        ui.rounded(frame, 10.0, theme::EDITOR_BACKGROUND);
        ui.outline(frame, 10.0, theme::white(0.12));
        let (left, right) = (frame.x + pad, frame.right() - pad);
        // Title row.
        let mut y = frame.y + pad + ui.px(11.0);
        let glass = ui.icon("magnifyingglass", 13.0, IconWeight::Semibold, left + ui.px(8.0), y, theme::TEXT_PRIMARY).max(ui.px(16.0));
        ui.text(if self.contents { "Find in Files" } else { "Quick Open" }, left + glass + ui.px(6.0), y, 13.0, 600, false, theme::TEXT_PRIMARY);
        let done_width = ui.measure("Done", 12.0, 500, false) + ui.px(20.0);
        self.done = Rect::new(right - done_width, y - ui.px(11.0), done_width, ui.px(22.0));
        ui.rounded(self.done, 5.0, theme::rgb(0x3A3A3A));
        ui.text("Done", self.done.x + ui.px(10.0), y, 12.0, 500, false, theme::TEXT_PRIMARY);
        let project = self.root.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
        ui.text_right(&project, self.done.x - ui.px(8.0), y, 13.0, 400, false, theme::TEXT_SECONDARY);
        // Field.
        y += ui.px(11.0 + 12.0);
        let field = Rect::new(left, y, right - left, ui.px(24.0));
        ui.rounded(field, 5.0, theme::rgb(0x1E1E1E));
        ui.outline(field, 5.0, theme::PRIMARY);
        let middle = field.y + field.height * 0.5;
        let line = ui.px(1.0).max(1.0);
        let caret = if self.query.is_empty() {
            ui.text(if self.contents { "Search project contents\u{2026}" } else { "Find a file by name or path\u{2026}" }, field.x + ui.px(7.0), middle, 13.0, 400, false, faded(theme::TEXT_SECONDARY, 0.7));
            0.0
        } else {
            ui.painter.scene.set_clip(Some(field));
            let width = ui.text(&self.query, field.x + ui.px(7.0), middle, 13.0, 400, false, theme::TEXT_PRIMARY);
            ui.painter.scene.set_clip(None);
            width + line
        };
        ui.painter.scene.fill(field.x + ui.px(7.0) + caret, middle - ui.px(8.0), line.max(2.0), ui.px(16.0), theme::ACCENT);
        y = field.bottom() + ui.px(12.0);
        if let Some(error) = &results.error {
            ui.text(error, left, y + ui.px(8.0), 13.0, 400, false, theme::rgb(0xC6B28E));
            y += error_height;
        }
        // Results.
        let list = Rect::new(left, y, right - left, list_height);
        self.list = list;
        self.rows.clear();
        let stale = results.query != self.query && !results.matches.is_empty() && self.contents;
        let plain_height = ui.px(9.0 + 15.0 + 9.0);
        let preview_height = ui.px(9.0 + 15.0 + 4.0 + 14.0 + 9.0);
        let spacing = ui.px(3.0);
        let content: f32 = results.matches.iter().map(|found| if found.preview.is_empty() { plain_height } else { preview_height } + spacing).sum();
        self.scroll = self.scroll.clamp(0.0, (content - list.height).max(0.0));
        self.selected = self.selected.min(results.matches.len().saturating_sub(1));
        ui.painter.scene.set_clip(Some(list));
        let mut top = list.y - self.scroll.round();
        for (index, found) in results.matches.iter().enumerate() {
            let row_height = if found.preview.is_empty() { plain_height } else { preview_height };
            let row = Rect::new(list.x, top, list.width, row_height);
            self.rows.push(row);
            if row.bottom() >= list.y && row.y <= list.bottom() {
                if index == self.selected {
                    ui.rounded(row, 6.0, theme::SELECTION);
                }
                // Icon, then the file's name, then its folder dimmed: the name is what the eye looks for.
                let opacity = if stale { 0.6 } else { 1.0 };
                let middle = row.y + ui.px(9.0 + 7.5);
                let icon_center = row.x + ui.px(9.0 + 8.0);
                crate::explorer::draw_file_icon(ui, std::path::Path::new(&found.path), icon_center, middle, opacity);
                let text_x = row.x + ui.px(9.0 + 16.0 + 7.0);
                let available = row.right() - ui.px(9.0) - text_x;
                let (folder, name) = match found.path.rsplit_once('/') {
                    Some((folder, name)) => (folder, name),
                    None => ("", found.path.as_str()),
                };
                let name = match found.line {
                    Some(line) => format!("{name}:{line}"),
                    None => name.to_string(),
                };
                let name = ui.fit_middle(&name, available, 12.5, 500, false);
                // Quick Open: the letters the query matched are drawn in the primary color.
                let matched = if self.contents { Vec::new() } else { subsequence(&name, &self.query) };
                let name_width = if matched.is_empty() {
                    ui.text(&name, text_x, middle, 12.5, 500, false, faded(theme::TEXT_PRIMARY, opacity))
                } else {
                    let characters: Vec<(usize, char)> = name.char_indices().collect();
                    let mut start = 0;
                    while start < characters.len() {
                        let lit = matched.contains(&start);
                        let mut end = start + 1;
                        while end < characters.len() && matched.contains(&end) == lit {
                            end += 1;
                        }
                        let (from, to) = (characters[start].0, characters.get(end).map_or(name.len(), |(offset, _)| *offset));
                        // Each run starts where the whole prefix ends, so spacing matches the plain name.
                        let x = text_x + if from == 0 { 0.0 } else { ui.measure(&name[..from], 12.5, 500, false) };
                        let color = if lit { theme::rgb(0x7AA7FF) } else { theme::TEXT_PRIMARY };
                        ui.text(&name[from..to], x, middle, 12.5, 500, false, faded(color, opacity));
                        start = end;
                    }
                    ui.measure(&name, 12.5, 500, false)
                };
                let folder_room = available - name_width - ui.px(8.0);
                if !folder.is_empty() && folder_room > ui.px(24.0) {
                    let folder = ui.fit_middle(folder, folder_room, 11.5, 400, false);
                    ui.text(&folder, text_x + name_width + ui.px(8.0), middle, 11.5, 400, false, faded(theme::TEXT_SECONDARY, opacity));
                }
                if !found.preview.is_empty() {
                    ui.painter.scene.set_clip(Some(Rect::new(text_x, list.y.max(row.y), (row.right() - ui.px(9.0) - text_x).max(0.0), (list.bottom().min(row.bottom()) - list.y.max(row.y)).max(0.0))));
                    let preview = found.preview.trim_start();
                    let preview_middle = row.y + ui.px(9.0 + 15.0 + 4.0 + 7.0);
                    // The matched text gets a quiet highlight, so it is clear why the line is listed.
                    if let Some((start, end)) = match_span(preview, &results.query) {
                        let before = ui.measure(&preview[..start], 11.0, 400, true);
                        let width = ui.measure(&preview[start..end], 11.0, 400, true);
                        let highlight = Rect::new(text_x + before - ui.px(1.0), preview_middle - ui.px(8.0), width + ui.px(2.0), ui.px(16.0));
                        ui.rounded(highlight, 3.0, theme::rgb(0x3A3F4A));
                    }
                    ui.text(preview, text_x, preview_middle, 11.0, 400, true, theme::TEXT_SECONDARY);
                    ui.painter.scene.set_clip(Some(list));
                }
            }
            top += row_height + spacing;
        }
        if results.matches.is_empty() && !results.loading {
            ui.text(if self.query.is_empty() && self.contents { "Enter text to search this project." } else { "No matching files" }, list.x, list.y + ui.px(20.0), 13.0, 400, false, theme::TEXT_SECONDARY);
        }
        ui.painter.scene.set_clip(None);
        // Scroll indicator.
        if content > list.height {
            let thumb = (list.height * list.height / content).max(ui.px(24.0));
            let travel = (list.height - thumb) * self.scroll / (content - list.height);
            ui.rounded(Rect::new(list.right() + ui.px(5.0), list.y + travel, ui.px(4.0), thumb), 2.0, theme::white(0.16));
        }
        // Footer: one line under a hairline, what was searched on the left and what was left out on
        // the right (when both fit).
        let separator = list.bottom() + ui.px(10.0);
        ui.painter.scene.fill(left, separator, right - left, line, theme::SEPARATOR);
        y = separator + line + ui.px(10.0 + 6.5);
        let status = if self.contents { "Up to 200 matches \u{b7} 20 per file \u{b7} files under 2 MB".to_string() } else { format!("{} indexed files \u{b7} up to 100 shown", results.files) };
        let status = if results.loading { format!("Searching\u{2026}  {status}") } else { status };
        let status_width = ui.text(&status, left, y, 10.0, 400, false, theme::TEXT_SECONDARY);
        let note = "Respects .gitignore \u{b7} dependency and build folders skipped";
        if left + status_width + ui.px(24.0) + ui.measure(note, 10.0, 400, false) <= right {
            ui.text_right(note, right, y, 10.0, 400, false, faded(theme::TEXT_SECONDARY, 0.8));
        }
    }
}

/// Which characters of `name` (by index) spell `query` in order, ignoring case: the letters a fuzzy file
/// match used, preferring runs (a later start that matches more letters in a row wins). Empty when
/// the query does not fit in the name (it matched folders instead).
fn subsequence(name: &str, query: &str) -> Vec<usize> {
    let name: Vec<char> = name.chars().flat_map(char::to_lowercase).collect();
    let query: Vec<char> = query.chars().filter(|character| !character.is_whitespace()).flat_map(char::to_lowercase).collect();
    if query.is_empty() || query.len() > name.len() {
        return Vec::new();
    }
    // runs[i][j]: the fewest runs that spell query[..=i] with query[i] at name[j]; from[i][j] where
    // query[i - 1] was.
    let (n, m) = (name.len(), query.len());
    let mut runs = vec![vec![usize::MAX; n]; m];
    let mut from = vec![vec![usize::MAX; n]; m];
    for j in 0..n {
        if name[j] == query[0] {
            runs[0][j] = 1;
        }
    }
    for i in 1..m {
        for j in i..n {
            if name[j] != query[i] {
                continue;
            }
            for k in (i - 1)..j {
                if runs[i - 1][k] == usize::MAX {
                    continue;
                }
                let total = runs[i - 1][k] + usize::from(k + 1 != j);
                if total < runs[i][j] {
                    runs[i][j] = total;
                    from[i][j] = k;
                }
            }
        }
    }
    let Some(last) = (0..n).filter(|&j| runs[m - 1][j] != usize::MAX).min_by_key(|&j| runs[m - 1][j]) else { return Vec::new() };
    let mut positions = vec![last];
    for i in (1..m).rev() {
        positions.push(from[i][*positions.last().unwrap()]);
    }
    positions.reverse();
    positions
}

/// Where `query` first occurs in `text`, ignoring case, as byte offsets into `text`.
fn match_span(text: &str, query: &str) -> Option<(usize, usize)> {
    let needle: Vec<char> = query.chars().flat_map(char::to_lowercase).collect();
    if needle.is_empty() {
        return None;
    }
    let characters: Vec<(usize, char)> = text.char_indices().collect();
    for start in 0..characters.len() {
        let mut matched = 0;
        let mut index = start;
        while matched < needle.len() && index < characters.len() {
            let lower: Vec<char> = characters[index].1.to_lowercase().collect();
            if needle[matched..].starts_with(&lower) {
                matched += lower.len();
                index += 1;
            } else {
                break;
            }
        }
        if matched == needle.len() {
            let end = characters.get(index).map_or(text.len(), |(offset, _)| *offset);
            return Some((characters[start].0, end));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    #[test]
    fn subsequence_prefers_letters_in_a_row() {
        assert_eq!(super::subsequence("workspace.rs", "space"), vec![4, 5, 6, 7, 8]);
        assert_eq!(super::subsequence("scroll.rs", "sc"), vec![0, 1]);
        assert_eq!(super::subsequence("README.md", "rmd"), vec![0, 7, 8]);
        assert!(super::subsequence("lib.rs", "xyz").is_empty());
    }

    #[test]
    fn match_span_ignores_case_and_keeps_byte_offsets() {
        assert_eq!(super::match_span("let ScrollSmoother = 1;", "smoother"), Some((10, 18)));
        assert_eq!(super::match_span("é Smoother", "SMOOTHER"), Some((3, 11)));
        assert_eq!(super::match_span("nothing", "smoother"), None);
        assert_eq!(super::match_span("anything", ""), None);
    }

    use super::*;

    #[test]
    fn ripgrep_json_becomes_matches() {
        let output = br#"{"type":"begin","data":{"path":{"text":"./src/a.rs"}}}
{"type":"match","data":{"path":{"text":"./src/a.rs"},"lines":{"text":"    let needle = 1;\n"},"line_number":12,"absolute_offset":0,"submatches":[]}}
not json
{"type":"match","data":{"path":{"text":"b.txt"},"lines":{"text":"needle\n"},"line_number":3}}
{"type":"end","data":{}}"#;
        let matches = parse_matches(output);
        assert_eq!(matches, vec![
            Match { path: "src/a.rs".into(), line: Some(12), preview: "let needle = 1;".into() },
            Match { path: "b.txt".into(), line: Some(3), preview: "needle".into() },
        ]);
    }

    #[test]
    fn matches_stop_at_the_limit() {
        let line = br#"{"type":"match","data":{"path":{"text":"a"},"lines":{"text":"x"},"line_number":1}}"#;
        let mut output = Vec::new();
        for _ in 0..300 {
            output.extend_from_slice(line);
            output.push(b'\n');
        }
        assert_eq!(parse_matches(&output).len(), MAX_MATCHES);
    }
}
