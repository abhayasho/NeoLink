//! The native text editor used when Neovim is not available (the Swift app's native text fallback):
//! plain text with line numbers, a cursor and selection, undo, the clipboard, smooth scrolling, and
//! saving that keeps the file's line endings and never overwrites a file changed on disk since it was
//! read. Files over 8 MiB, or that are not UTF-8 text, open read-only.

use std::path::Path;

use neolink_core::scroll::{ScrollSmoother, Smoothing};
use winit::keyboard::{Key, ModifiersState, NamedKey};

use crate::frame::{Next, Painter};
use crate::render::Rect;
use crate::text::CellMetrics;
use crate::theme;

/// Larger files open read-only (the Swift app's native text preview limit).
pub const EDIT_LIMIT: u64 = 8 * 1024 * 1024;
const TAB: usize = 4;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Default)]
pub struct Position {
    pub line: usize,
    /// In characters.
    pub column: usize,
}

#[derive(Clone)]
struct Snapshot {
    lines: Vec<String>,
    cursor: Position,
}

/// What a key or click did.
#[derive(Debug, PartialEq, Eq)]
pub enum Effect {
    Nothing,
    Moved,
    Edited,
}

pub struct NativeEditor {
    pub path: String,
    lines: Vec<String>,
    crlf: bool,
    final_newline: bool,
    pub read_only: bool,
    cursor: Position,
    anchor: Option<Position>,
    /// The column a vertical move tries to return to.
    goal: usize,
    saved: Vec<String>,
    undo: Vec<Snapshot>,
    redo: Vec<Snapshot>,
    /// Typing joins one undo step until something else happens.
    typing: bool,
    /// The file as read: (length, modification time) to notice changes made by others.
    disk: Option<(u64, std::time::SystemTime)>,
    scroll: f64,
    smoother: ScrollSmoother,
    rect: Rect,
    gutter: f32,
    cell: CellMetrics,
    revision: u64,
}

fn signature(path: &str) -> Option<(u64, std::time::SystemTime)> {
    let metadata = std::fs::metadata(path).ok()?;
    Some((metadata.len(), metadata.modified().ok()?))
}

/// The display column of character `column` in `line` (tabs expand to the next multiple of 4).
fn display_column(line: &str, column: usize) -> usize {
    let mut display = 0;
    for character in line.chars().take(column) {
        display = if character == '\t' { (display / TAB + 1) * TAB } else { display + 1 };
    }
    display
}

/// The character column nearest display column `target` in `line`.
fn char_column(line: &str, target: usize) -> usize {
    let mut display = 0;
    for (index, character) in line.chars().enumerate() {
        let next = if character == '\t' { (display / TAB + 1) * TAB } else { display + 1 };
        if target < next && target - display < next - target {
            return index;
        }
        if target < next {
            return index + 1;
        }
        display = next;
    }
    line.chars().count()
}

fn byte_index(line: &str, column: usize) -> usize {
    line.char_indices().nth(column).map_or(line.len(), |(index, _)| index)
}

fn is_word(character: char) -> bool {
    character.is_alphanumeric() || character == '_'
}

impl NativeEditor {
    pub fn open(path: &str, cell: CellMetrics) -> Result<NativeEditor, String> {
        let metadata = std::fs::metadata(path).map_err(|error| format!("{path}: {error}"))?;
        let too_large = metadata.len() > EDIT_LIMIT;
        let bytes = if too_large {
            let mut bytes = vec![0u8; EDIT_LIMIT as usize];
            use std::io::Read;
            let mut file = std::fs::File::open(path).map_err(|error| error.to_string())?;
            let read = file.read(&mut bytes).map_err(|error| error.to_string())?;
            bytes.truncate(read);
            bytes
        } else {
            std::fs::read(path).map_err(|error| format!("{path}: {error}"))?
        };
        let (text, binary) = match String::from_utf8(bytes) {
            Ok(text) => (text, false),
            Err(error) => (String::from_utf8_lossy(error.as_bytes()).into_owned(), true),
        };
        let crlf = text.contains("\r\n");
        let final_newline = text.ends_with('\n');
        let body = text.strip_suffix('\n').unwrap_or(&text);
        let lines: Vec<String> = body.split('\n').map(|line| line.strip_suffix('\r').unwrap_or(line).to_string()).collect();
        Ok(NativeEditor {
            path: path.to_string(),
            saved: lines.clone(),
            lines,
            crlf,
            final_newline,
            read_only: too_large || binary,
            cursor: Position::default(),
            anchor: None,
            goal: 0,
            undo: Vec::new(),
            redo: Vec::new(),
            typing: false,
            disk: signature(path),
            scroll: 0.0,
            smoother: ScrollSmoother::new(Smoothing::Auto),
            rect: Rect::default(),
            gutter: 0.0,
            cell,
            revision: 0,
        })
    }

    pub fn is_modified(&self) -> bool {
        self.lines != self.saved
    }

    pub fn revision(&self) -> u64 {
        self.revision ^ (self.scroll.to_bits()).rotate_left(17)
    }

    /// Whole lines, for the benchmark and tests.
    pub fn text(&self) -> String {
        self.lines.join("\n")
    }

    fn line_length(&self, line: usize) -> usize {
        self.lines[line].chars().count()
    }

    fn selection(&self) -> Option<(Position, Position)> {
        let anchor = self.anchor?;
        (anchor != self.cursor).then(|| if anchor < self.cursor { (anchor, self.cursor) } else { (self.cursor, anchor) })
    }

    pub fn selected_text(&self) -> Option<String> {
        let (start, end) = self.selection()?;
        let mut out = String::new();
        for line in start.line..=end.line {
            let text = &self.lines[line];
            let from = if line == start.line { byte_index(text, start.column) } else { 0 };
            let to = if line == end.line { byte_index(text, end.column) } else { text.len() };
            out.push_str(&text[from..to]);
            if line != end.line {
                out.push('\n');
            }
        }
        Some(out)
    }

    fn remember(&mut self) {
        self.undo.push(Snapshot { lines: self.lines.clone(), cursor: self.cursor });
        if self.undo.len() > 200 {
            self.undo.remove(0);
        }
        self.redo.clear();
    }

    fn delete_selection(&mut self) -> bool {
        let Some((start, end)) = self.selection() else { return false };
        let tail = self.lines[end.line][byte_index(&self.lines[end.line], end.column)..].to_string();
        let head_end = byte_index(&self.lines[start.line], start.column);
        self.lines[start.line].truncate(head_end);
        self.lines[start.line].push_str(&tail);
        self.lines.drain(start.line + 1..=end.line);
        self.cursor = start;
        self.anchor = None;
        true
    }

    /// Inserts `text` at the cursor, replacing the selection.
    pub fn insert(&mut self, text: &str) -> Effect {
        if self.read_only {
            return Effect::Nothing;
        }
        let single = !text.contains('\n') && text.chars().count() == 1;
        if !(single && self.typing && self.selection().is_none()) {
            self.remember();
        }
        self.typing = single;
        self.delete_selection();
        let text = text.replace("\r\n", "\n").replace('\r', "\n");
        let line = &mut self.lines[self.cursor.line];
        let at = byte_index(line, self.cursor.column);
        let tail = line.split_off(at);
        let mut parts = text.split('\n');
        if let Some(first) = parts.next() {
            self.lines[self.cursor.line].push_str(first);
            self.cursor.column += first.chars().count();
        }
        for part in parts {
            self.cursor.line += 1;
            self.lines.insert(self.cursor.line, part.to_string());
            self.cursor.column = part.chars().count();
        }
        self.lines[self.cursor.line].push_str(&tail);
        self.goal = display_column(&self.lines[self.cursor.line], self.cursor.column);
        self.revision += 1;
        self.keep_cursor_visible();
        Effect::Edited
    }

    fn backspace(&mut self, word: bool) -> Effect {
        if self.read_only {
            return Effect::Nothing;
        }
        self.remember();
        self.typing = false;
        if !self.delete_selection() {
            let start = if word { self.word_left(self.cursor) } else { self.left(self.cursor) };
            if start == self.cursor {
                self.undo.pop();
                return Effect::Nothing;
            }
            self.anchor = Some(start);
            self.delete_selection();
        }
        self.after_edit()
    }

    fn delete_forward(&mut self) -> Effect {
        if self.read_only {
            return Effect::Nothing;
        }
        self.remember();
        self.typing = false;
        if !self.delete_selection() {
            let end = self.right(self.cursor);
            if end == self.cursor {
                self.undo.pop();
                return Effect::Nothing;
            }
            self.anchor = Some(end);
            self.delete_selection();
        }
        self.after_edit()
    }

    fn after_edit(&mut self) -> Effect {
        self.goal = display_column(&self.lines[self.cursor.line], self.cursor.column);
        self.revision += 1;
        self.keep_cursor_visible();
        Effect::Edited
    }

    fn left(&self, at: Position) -> Position {
        if at.column > 0 {
            Position { column: at.column - 1, ..at }
        } else if at.line > 0 {
            Position { line: at.line - 1, column: self.line_length(at.line - 1) }
        } else {
            at
        }
    }

    fn right(&self, at: Position) -> Position {
        if at.column < self.line_length(at.line) {
            Position { column: at.column + 1, ..at }
        } else if at.line + 1 < self.lines.len() {
            Position { line: at.line + 1, column: 0 }
        } else {
            at
        }
    }

    fn word_left(&self, at: Position) -> Position {
        let characters: Vec<char> = self.lines[at.line].chars().collect();
        if at.column == 0 {
            return self.left(at);
        }
        let mut column = at.column;
        while column > 0 && !is_word(characters[column - 1]) {
            column -= 1;
        }
        while column > 0 && is_word(characters[column - 1]) {
            column -= 1;
        }
        Position { column, ..at }
    }

    fn word_right(&self, at: Position) -> Position {
        let characters: Vec<char> = self.lines[at.line].chars().collect();
        if at.column >= characters.len() {
            return self.right(at);
        }
        let mut column = at.column;
        while column < characters.len() && !is_word(characters[column]) {
            column += 1;
        }
        while column < characters.len() && is_word(characters[column]) {
            column += 1;
        }
        Position { column, ..at }
    }

    fn vertical(&self, at: Position, lines: isize) -> Position {
        let line = (at.line as isize + lines).clamp(0, self.lines.len() as isize - 1) as usize;
        Position { line, column: char_column(&self.lines[line], self.goal) }
    }

    fn move_to(&mut self, to: Position, extend: bool, keep_goal: bool) -> Effect {
        if extend {
            self.anchor.get_or_insert(self.cursor);
        } else {
            self.anchor = None;
        }
        self.cursor = to;
        if !keep_goal {
            self.goal = display_column(&self.lines[to.line], to.column);
        }
        self.typing = false;
        self.revision += 1;
        self.keep_cursor_visible();
        Effect::Moved
    }

    fn visible_lines(&self) -> usize {
        ((self.rect.height / self.cell.height).floor() as usize).max(1)
    }

    /// Scrolls just enough to show the cursor's line.
    fn keep_cursor_visible(&mut self) {
        let height = self.cell.height as f64;
        let top = self.cursor.line as f64 * height;
        let view = self.rect.height as f64;
        if top < self.scroll {
            self.scroll = top;
            self.smoother.cancel();
        } else if top + height > self.scroll + view && view > 0.0 {
            self.scroll = top + height - view;
            self.smoother.cancel();
        }
    }

    pub fn select_all(&mut self) {
        self.anchor = Some(Position::default());
        let last = self.lines.len() - 1;
        self.cursor = Position { line: last, column: self.line_length(last) };
        self.revision += 1;
    }

    pub fn undo(&mut self) {
        if let Some(snapshot) = self.undo.pop() {
            self.redo.push(Snapshot { lines: std::mem::replace(&mut self.lines, snapshot.lines), cursor: self.cursor });
            self.cursor = snapshot.cursor;
            self.finish_history();
        }
    }

    pub fn redo(&mut self) {
        if let Some(snapshot) = self.redo.pop() {
            self.undo.push(Snapshot { lines: std::mem::replace(&mut self.lines, snapshot.lines), cursor: self.cursor });
            self.cursor = snapshot.cursor;
            self.finish_history();
        }
    }

    fn finish_history(&mut self) {
        self.cursor.line = self.cursor.line.min(self.lines.len() - 1);
        self.cursor.column = self.cursor.column.min(self.line_length(self.cursor.line));
        self.anchor = None;
        self.typing = false;
        self.revision += 1;
        self.keep_cursor_visible();
    }

    /// Cut: copies the selection to `clipboard` and removes it.
    pub fn cut(&mut self) -> Option<String> {
        let text = self.selected_text()?;
        if self.read_only {
            return Some(text);
        }
        self.remember();
        self.delete_selection();
        self.after_edit();
        Some(text)
    }

    /// Writes the text back with the line endings it had. Refuses if the file changed on disk since
    /// it was read (the Swift app's external-edit check).
    pub fn save(&mut self) -> Result<(), String> {
        if self.read_only {
            return Err("This file is open read-only (larger than 8 MiB, or not UTF-8 text).".into());
        }
        if signature(&self.path) != self.disk {
            return Err(format!("{} was changed by another program since it was opened; it was not overwritten.", Path::new(&self.path).file_name().and_then(|name| name.to_str()).unwrap_or("The file")));
        }
        let newline = if self.crlf { "\r\n" } else { "\n" };
        let mut text = self.lines.join(newline);
        if self.final_newline {
            text.push_str(newline);
        }
        let temporary = format!("{}.neolink-save", self.path);
        std::fs::write(&temporary, text.as_bytes()).and_then(|_| std::fs::rename(&temporary, &self.path)).map_err(|error| {
            let _ = std::fs::remove_file(&temporary);
            format!("Could not save: {error}")
        })?;
        self.disk = signature(&self.path);
        self.saved = self.lines.clone();
        self.revision += 1;
        Ok(())
    }

    /// A key, with each platform's conventions: on macOS Command-arrows go to line and document
    /// ends and Option-arrows move by word; elsewhere Control-arrows move by word and Control-Home/End
    /// go to the document's ends.
    pub fn key(&mut self, key: &Key, text: Option<&str>, modifiers: ModifiersState) -> Effect {
        let command = if cfg!(target_os = "macos") { modifiers.super_key() } else { modifiers.control_key() };
        // Command-arrows exist only on macOS (on Windows, Control-arrows are word movement).
        let line_jump = cfg!(target_os = "macos") && modifiers.super_key();
        let word = if cfg!(target_os = "macos") { modifiers.alt_key() } else { modifiers.control_key() };
        let extend = modifiers.shift_key();
        let page = self.visible_lines().saturating_sub(1).max(1) as isize;
        let last = self.lines.len() - 1;
        let to = match key {
            Key::Named(NamedKey::ArrowLeft) if line_jump => Some((Position { column: 0, ..self.cursor }, false)),
            Key::Named(NamedKey::ArrowRight) if line_jump => Some((Position { column: self.line_length(self.cursor.line), ..self.cursor }, false)),
            Key::Named(NamedKey::ArrowUp) if line_jump => Some((Position::default(), false)),
            Key::Named(NamedKey::ArrowDown) if line_jump => Some((Position { line: last, column: self.line_length(last) }, false)),
            Key::Named(NamedKey::Home) if modifiers.control_key() || modifiers.super_key() => Some((Position::default(), false)),
            Key::Named(NamedKey::End) if modifiers.control_key() || modifiers.super_key() => Some((Position { line: last, column: self.line_length(last) }, false)),
            Key::Named(NamedKey::ArrowLeft) if word => Some((self.word_left(self.cursor), false)),
            Key::Named(NamedKey::ArrowRight) if word => Some((self.word_right(self.cursor), false)),
            Key::Named(NamedKey::ArrowLeft) => Some(match self.selection().filter(|_| !extend) {
                Some((start, _)) => (start, false),
                None => (self.left(self.cursor), false),
            }),
            Key::Named(NamedKey::ArrowRight) => Some(match self.selection().filter(|_| !extend) {
                Some((_, end)) => (end, false),
                None => (self.right(self.cursor), false),
            }),
            Key::Named(NamedKey::ArrowUp) => Some((self.vertical(self.cursor, -1), true)),
            Key::Named(NamedKey::ArrowDown) => Some((self.vertical(self.cursor, 1), true)),
            Key::Named(NamedKey::PageUp) => Some((self.vertical(self.cursor, -page), true)),
            Key::Named(NamedKey::PageDown) => Some((self.vertical(self.cursor, page), true)),
            Key::Named(NamedKey::Home) => Some((Position { column: 0, ..self.cursor }, false)),
            Key::Named(NamedKey::End) => Some((Position { column: self.line_length(self.cursor.line), ..self.cursor }, false)),
            _ => None,
        };
        if let Some((to, keep_goal)) = to {
            return self.move_to(to, extend, keep_goal);
        }
        match key {
            Key::Named(NamedKey::Backspace) => self.backspace(word),
            Key::Named(NamedKey::Delete) => self.delete_forward(),
            Key::Named(NamedKey::Enter) => {
                // The new line starts with the indentation of this one.
                let indent: String = self.lines[self.cursor.line].chars().take_while(|character| *character == ' ' || *character == '\t').collect();
                self.typing = false;
                self.insert(&format!("\n{indent}"))
            }
            Key::Named(NamedKey::Tab) => {
                let column = display_column(&self.lines[self.cursor.line], self.cursor.column);
                self.insert(&" ".repeat(TAB - column % TAB))
            }
            Key::Named(NamedKey::Escape) => {
                if self.anchor.take().is_some() {
                    self.revision += 1;
                    Effect::Moved
                } else {
                    Effect::Nothing
                }
            }
            _ if command || modifiers.control_key() => Effect::Nothing,
            _ => match text.filter(|text| !text.is_empty() && !text.chars().any(char::is_control)) {
                Some(text) => self.insert(text),
                None => Effect::Nothing,
            },
        }
    }

    fn position_at(&self, x: f32, y: f32) -> Position {
        let row = ((y - self.rect.y + self.scroll as f32) / self.cell.height).floor().max(0.0) as usize;
        let line = row.min(self.lines.len() - 1);
        let display = ((x - self.rect.x - self.gutter) / self.cell.width).round().max(0.0) as usize;
        Position { line, column: char_column(&self.lines[line], display) }
    }

    /// A press (`clicks` 2 selects a word, 3 a line), or a drag with the button held.
    pub fn mouse(&mut self, x: f32, y: f32, clicks: u8, drag: bool, extend: bool) {
        let at = self.position_at(x, y);
        self.typing = false;
        if drag {
            self.anchor.get_or_insert(self.cursor);
            self.cursor = at;
        } else {
            match clicks {
                2 => {
                    self.anchor = Some(self.word_left(Position { column: (at.column + 1).min(self.line_length(at.line)), ..at }));
                    self.cursor = self.word_right(at);
                }
                3 => {
                    self.anchor = Some(Position { line: at.line, column: 0 });
                    self.cursor = if at.line + 1 < self.lines.len() { Position { line: at.line + 1, column: 0 } } else { Position { line: at.line, column: self.line_length(at.line) } };
                }
                _ => {
                    if extend {
                        self.anchor.get_or_insert(self.cursor);
                    } else {
                        self.anchor = None;
                    }
                    self.cursor = at;
                }
            }
        }
        self.goal = display_column(&self.lines[self.cursor.line], self.cursor.column);
        self.revision += 1;
    }

    pub fn scroll_input(&mut self, time: f64, delta: f64, began: bool, period: f64) {
        if began {
            self.smoother.begin_gesture();
        }
        // Fingers moving down show earlier lines.
        self.smoother.push(time, -delta, period);
    }

    /// Draws the text in `rect` and says when the next frame is needed.
    pub fn build(&mut self, painter: &mut Painter, rect: Rect, focused: bool, display: f64, period: f64) -> Next {
        let cell = painter.text.cell;
        self.cell = cell;
        self.rect = rect;
        let content = self.lines.len() as f64 * cell.height as f64;
        let limit = (content - rect.height as f64 + cell.height as f64 * 3.0).max(0.0);
        let wanted = self.scroll + self.smoother.advance(display, period);
        self.scroll = wanted.clamp(0.0, limit);
        if wanted != self.scroll {
            self.smoother.cancel();
        }
        let scroll = self.scroll.round() as f32;
        let digits = (self.lines.len().max(1) as f64).log10().floor() as usize + 1;
        self.gutter = ((digits.max(3) + 2) as f32 * cell.width).round();
        painter.scene.set_clip(Some(rect));
        let first = (scroll / cell.height).floor() as usize;
        let count = (rect.height / cell.height).ceil() as usize + 1;
        let selection = self.selection();
        let text_color = theme::TEXT_PRIMARY;
        let number_color = theme::TEXT_SECONDARY;
        for line in first..(first + count).min(self.lines.len()) {
            let y = rect.y + line as f32 * cell.height - scroll;
            let text = &self.lines[line];
            if let Some((start, end)) = selection.filter(|(start, end)| start.line <= line && line <= end.line) {
                let from = if line == start.line { display_column(text, start.column) } else { 0 };
                let to = if line == end.line { display_column(text, end.column) } else { display_column(text, text.chars().count()) + 1 };
                if to > from {
                    painter.scene.fill(rect.x + self.gutter + from as f32 * cell.width, y, (to - from) as f32 * cell.width, cell.height, theme::TERMINAL_SELECTION);
                }
            }
            // Line number, right-aligned in the gutter.
            let number = (line + 1).to_string();
            let start = digits.max(3) + 1 - number.len();
            let number_color = if line == self.cursor.line { text_color } else { number_color };
            for (index, character) in number.chars().enumerate() {
                if let Some(glyph) = painter.text.cell_glyph(painter.queue, character, false, false) {
                    painter.scene.glyph(glyph.sprite, rect.x + (start + index) as f32 * cell.width + glyph.x as f32, y + cell.baseline + glyph.y as f32, number_color);
                }
            }
            let mut column = 0usize;
            let right = rect.right();
            for character in text.chars() {
                let x = rect.x + self.gutter + column as f32 * cell.width;
                if x > right {
                    break;
                }
                if character == '\t' {
                    column = (column / TAB + 1) * TAB;
                    continue;
                }
                if let Some(glyph) = painter.text.cell_glyph(painter.queue, character, false, false) {
                    painter.scene.glyph(glyph.sprite, x + glyph.x as f32, y + cell.baseline + glyph.y as f32, text_color);
                }
                column += 1;
            }
            if line == self.cursor.line && focused && !self.read_only {
                let x = rect.x + self.gutter + display_column(text, self.cursor.column) as f32 * cell.width;
                painter.scene.fill(x, y, (cell.width / 6.0).round().max(2.0), cell.height, theme::ACCENT);
            }
        }
        painter.scene.set_clip(None);
        match self.smoother.next_visible_change(display, period, self.scroll) {
            None => Next::Idle,
            Some(at) if at <= display + 1.5 * period => Next::Soon,
            Some(at) => Next::At(at),
        }
    }

    /// Selects the next match of `query` (any case), from the current match's start when `restart`
    /// (the query changed) or after it, wrapping round. Returns `false` if the text is nowhere.
    pub fn find(&mut self, query: &str, restart: bool) -> bool {
        let needle: Vec<char> = query.chars().collect();
        if needle.is_empty() {
            return false;
        }
        let same = |a: char, b: char| a == b || a.to_lowercase().eq(b.to_lowercase());
        let start = if restart { self.selection().map_or(self.cursor, |(start, _)| start) } else { self.cursor };
        let total = self.lines.len();
        for step in 0..=total {
            let line = (start.line + step) % total;
            let characters: Vec<char> = self.lines[line].chars().collect();
            let from = if step == 0 { start.column } else { 0 };
            if characters.len() < needle.len() {
                continue;
            }
            for column in from..=characters.len() - needle.len() {
                if characters[column..column + needle.len()].iter().zip(&needle).all(|(a, b)| same(*a, *b)) {
                    self.anchor = Some(Position { line, column });
                    self.cursor = Position { line, column: column + needle.len() };
                    self.goal = display_column(&self.lines[line], self.cursor.column);
                    self.typing = false;
                    self.revision += 1;
                    self.keep_cursor_visible();
                    return true;
                }
            }
        }
        false
    }

    /// The lines in view (for screen readers).
    pub fn visible_text(&self) -> String {
        let height = self.cell.height.max(1.0) as f64;
        let first = ((self.scroll / height).floor() as usize).min(self.lines.len().saturating_sub(1));
        let count = (self.rect.height as f64 / height).ceil() as usize + 1;
        self.lines[first..(first + count).min(self.lines.len())].join("\n")
    }

    /// `(pixels scrolled, lines in the document)`.
    pub fn extent(&self) -> (f64, usize) {
        (self.scroll, self.lines.len())
    }

    pub fn cursor_label(&self) -> String {
        format!("Ln {}, Col {}", self.cursor.line + 1, display_column(&self.lines[self.cursor.line], self.cursor.column) + 1)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cell() -> CellMetrics {
        CellMetrics { width: 10.0, height: 20.0, baseline: 15.0, font_pixels: 16.0 }
    }

    fn scratch(name: &str, contents: &[u8]) -> String {
        let path = std::env::temp_dir().join(format!("neolink-native-{}-{name}", std::process::id()));
        std::fs::write(&path, contents).unwrap();
        path.to_string_lossy().into_owned()
    }

    fn press(editor: &mut NativeEditor, key: NamedKey) {
        editor.key(&Key::Named(key), None, ModifiersState::empty());
    }

    #[test]
    fn edits_keep_line_endings_and_undo() {
        let path = scratch("crlf.txt", b"one\r\n\ttwo\r\n");
        let mut editor = NativeEditor::open(&path, cell()).unwrap();
        assert_eq!(editor.text(), "one\n\ttwo");
        press(&mut editor, NamedKey::End);
        editor.insert("!");
        press(&mut editor, NamedKey::ArrowDown);
        // Display column 4 on "\ttwo" is just after the tab.
        assert_eq!(editor.cursor_label(), "Ln 2, Col 5");
        press(&mut editor, NamedKey::End);
        press(&mut editor, NamedKey::Enter);
        editor.insert("x");
        assert_eq!(editor.text(), "one!\n\ttwo\n\tx");
        assert!(editor.is_modified());
        editor.save().unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"one!\r\n\ttwo\r\n\tx\r\n");
        assert!(!editor.is_modified());
        editor.undo();
        assert_eq!(editor.text(), "one!\n\ttwo\n\t");
        editor.undo();
        assert_eq!(editor.text(), "one!\n\ttwo");
        editor.redo();
        editor.redo();
        assert_eq!(editor.text(), "one!\n\ttwo\n\tx");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn selection_cut_and_paste() {
        let path = scratch("select.txt", b"alpha beta\ngamma\n");
        let mut editor = NativeEditor::open(&path, cell()).unwrap();
        // Word movement: Option on macOS, Control elsewhere.
        let word = if cfg!(target_os = "macos") { ModifiersState::ALT } else { ModifiersState::CONTROL };
        editor.key(&Key::Named(NamedKey::ArrowRight), None, word);
        editor.key(&Key::Named(NamedKey::ArrowDown), None, ModifiersState::SHIFT);
        assert_eq!(editor.selected_text().as_deref(), Some(" beta\ngamma"));
        let cut = editor.cut().unwrap();
        assert_eq!(cut, " beta\ngamma");
        assert_eq!(editor.text(), "alpha");
        editor.insert(" pasted\nlines");
        assert_eq!(editor.text(), "alpha pasted\nlines");
        editor.select_all();
        assert_eq!(editor.selected_text().as_deref(), Some("alpha pasted\nlines"));
        press(&mut editor, NamedKey::Backspace);
        assert_eq!(editor.text(), "");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn find_selects_matches_in_order_and_wraps() {
        let path = scratch("find.txt", "Alpha beta\nbeta ALPHA\n".as_bytes());
        let mut editor = NativeEditor::open(&path, cell()).unwrap();
        assert!(editor.find("alpha", true));
        assert_eq!(editor.selected_text().as_deref(), Some("Alpha"));
        // Typing more of the query keeps the same match; Return goes to the next.
        assert!(editor.find("alpha", true));
        assert_eq!(editor.cursor_label(), "Ln 1, Col 6");
        assert!(editor.find("alpha", false));
        assert_eq!((editor.selected_text().as_deref(), editor.cursor_label().as_str()), (Some("ALPHA"), "Ln 2, Col 11"));
        assert!(editor.find("alpha", false));
        assert_eq!(editor.cursor_label(), "Ln 1, Col 6");
        assert!(!editor.find("gamma", false));
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn a_file_changed_on_disk_is_not_overwritten() {
        let path = scratch("external.txt", b"mine\n");
        let mut editor = NativeEditor::open(&path, cell()).unwrap();
        editor.insert("x");
        std::thread::sleep(std::time::Duration::from_millis(20));
        std::fs::write(&path, b"theirs, longer\n").unwrap();
        assert!(editor.save().is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"theirs, longer\n");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn tabs_map_display_columns() {
        assert_eq!(display_column("\tab", 1), 4);
        assert_eq!(display_column("a\tb", 2), 4);
        assert_eq!(char_column("\tab", 4), 1);
        assert_eq!(char_column("\tab", 1), 0);
        assert_eq!(char_column("ab", 9), 2);
        let path = scratch("binary.bin", &[0x66, 0xff, 0x00]);
        assert!(NativeEditor::open(&path, cell()).unwrap().read_only);
        let _ = std::fs::remove_file(&path);
    }
}
