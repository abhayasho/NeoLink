//! The editor's screen, from Neovim's `ext_linegrid` `redraw` events (grid 1 only).
//!
//! Events are applied to a working copy; `flush` publishes it. Nothing a reader of [`GridModel::screen`]
//! sees is ever half of a redraw. Rows are shared (`Arc`), so publishing copies pointers, and a row that
//! did not change keeps its identity from one screen to the next.

use rmpv::Value;
use std::collections::HashMap;
use std::sync::Arc;

/// What a cell shows. An empty cluster is the right half of the double-width cell before it.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Text {
    Char(char),
    /// A grapheme cluster of more than one scalar, or the empty string.
    Cluster(Arc<str>),
}

impl Text {
    fn from_str(text: &str) -> Text {
        let mut chars = text.chars();
        match (chars.next(), chars.next()) {
            (Some(only), None) => Text::Char(only),
            _ => Text::Cluster(Arc::from(text)),
        }
    }

    pub fn is_continuation(&self) -> bool {
        matches!(self, Text::Cluster(cluster) if cluster.is_empty())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Cell {
    pub text: Text,
    pub highlight: u32,
}

impl Cell {
    pub fn blank() -> Cell {
        Cell { text: Text::Char(' '), highlight: 0 }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Underline {
    None,
    Line,
    Curl,
    Double,
    Dotted,
    Dashed,
}

/// A highlight definition (`hl_attr_define`). Colours are 0xRRGGBB; `None` is the default colour.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Highlight {
    pub foreground: Option<u32>,
    pub background: Option<u32>,
    pub special: Option<u32>,
    pub reverse: bool,
    pub italic: bool,
    pub bold: bool,
    pub strikethrough: bool,
    pub underline: Underline,
}

impl Default for Highlight {
    fn default() -> Self {
        Highlight { foreground: None, background: None, special: None, reverse: false, italic: false, bold: false, strikethrough: false, underline: Underline::None }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Defaults {
    pub foreground: u32,
    pub background: u32,
    /// `None` when Neovim sends -1: underlines then follow the cell's foreground.
    pub special: Option<u32>,
}

impl Default for Defaults {
    fn default() -> Self {
        Defaults { foreground: 0xd8d8d8, background: 0x181818, special: None }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CursorShape {
    Block,
    Horizontal,
    Vertical,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModeInfo {
    pub shape: CursorShape,
    pub blinks: bool,
    pub name: String,
}

/// A full-width scroll of rows `top..bottom`; `lines` > 0 moved the content up.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Scroll {
    pub top: usize,
    pub bottom: usize,
    pub lines: i64,
}

pub type Row = Arc<Vec<Cell>>;

/// The screen as of a `flush`.
#[derive(Clone, Debug)]
pub struct Screen {
    pub columns: usize,
    pub rows: Vec<Row>,
    pub cursor: (usize, usize),
    pub mode: usize,
    pub modes: Arc<Vec<ModeInfo>>,
    pub highlights: Arc<HashMap<u32, Highlight>>,
    pub defaults: Defaults,
    pub busy: bool,
    /// Increments whenever an existing highlight or the default colours change meaning: anything drawn
    /// with the previous epoch's styles is stale.
    pub style_epoch: u64,
    /// Increments at every flush that changed something.
    pub generation: u64,
    /// Full-width scrolls since the previous screen, in order (a hint for smooth scrolling; the rows are
    /// authoritative).
    pub scrolls: Vec<Scroll>,
}

impl Screen {
    pub fn cursor_shape(&self) -> CursorShape {
        self.modes.get(self.mode).map(|mode| mode.shape).unwrap_or(CursorShape::Block)
    }

    pub fn highlight(&self, id: u32) -> Highlight {
        self.highlights.get(&id).copied().unwrap_or_default()
    }

    /// A row as plain text (tests, debugging).
    pub fn row_text(&self, row: usize) -> String {
        let mut text = String::new();
        for cell in self.rows[row].iter() {
            match &cell.text {
                Text::Char(character) => text.push(*character),
                Text::Cluster(cluster) => text.push_str(cluster),
            }
        }
        text
    }
}

const MAX_DIMENSION: usize = 4096;

/// Applies `redraw` events. Owned by the thread that reads Neovim's output.
pub struct GridModel {
    columns: usize,
    rows: Vec<Row>,
    cursor: (usize, usize),
    mode: usize,
    modes: Arc<Vec<ModeInfo>>,
    highlights: Arc<HashMap<u32, Highlight>>,
    defaults: Defaults,
    busy: bool,
    style_epoch: u64,
    scrolls: Vec<Scroll>,
    changed: bool,
    published: Screen,
}

fn blank_row(columns: usize) -> Row {
    Arc::new(vec![Cell::blank(); columns])
}

fn integer(value: &Value) -> Option<i64> {
    value.as_i64().or_else(|| value.as_u64().map(|v| v as i64))
}

fn lookup<'a>(map: &'a Value, key: &str) -> Option<&'a Value> {
    map.as_map()?.iter().find(|(name, _)| name.as_str() == Some(key)).map(|(_, value)| value)
}

impl GridModel {
    pub fn new(columns: usize, rows: usize) -> GridModel {
        let (columns, row_count) = (columns.clamp(1, MAX_DIMENSION), rows.clamp(1, MAX_DIMENSION));
        let rows: Vec<Row> = (0..row_count).map(|_| blank_row(columns)).collect();
        let modes = Arc::new(Vec::new());
        let highlights = Arc::new(HashMap::new());
        let published = Screen {
            columns,
            rows: rows.clone(),
            cursor: (0, 0),
            mode: 0,
            modes: modes.clone(),
            highlights: highlights.clone(),
            defaults: Defaults::default(),
            busy: false,
            style_epoch: 0,
            generation: 0,
            scrolls: Vec::new(),
        };
        GridModel { columns, rows, cursor: (0, 0), mode: 0, modes, highlights, defaults: Defaults::default(), busy: false, style_epoch: 0, scrolls: Vec::new(), changed: false, published }
    }

    /// The screen as of the last `flush`.
    pub fn screen(&self) -> &Screen {
        &self.published
    }

    /// Applies the parameters of one `redraw` notification: `[name, args...]` batches. Returns how many
    /// `flush` events published a changed screen.
    pub fn apply(&mut self, events: &[Value]) -> usize {
        let mut published = 0;
        for event in events {
            let Some(items) = event.as_array() else { continue };
            let Some(name) = items.first().and_then(Value::as_str) else { continue };
            let calls = &items[1..];
            match name {
                "grid_line" => calls.iter().for_each(|call| self.grid_line(call)),
                "grid_scroll" => calls.iter().for_each(|call| self.grid_scroll(call)),
                "grid_cursor_goto" => {
                    for call in calls {
                        if let Some([grid, row, column, ..]) = call.as_array().map(Vec::as_slice) {
                            if integer(grid) == Some(1) {
                                if let (Some(row), Some(column)) = (integer(row), integer(column)) {
                                    self.cursor = (row.max(0) as usize, column.max(0) as usize);
                                    self.changed = true;
                                }
                            }
                        }
                    }
                }
                "grid_resize" => {
                    for call in calls {
                        if let Some([grid, width, height, ..]) = call.as_array().map(Vec::as_slice) {
                            if integer(grid) == Some(1) {
                                if let (Some(width), Some(height)) = (integer(width), integer(height)) {
                                    self.resize(width, height);
                                }
                            }
                        }
                    }
                }
                "grid_clear" => {
                    for call in calls {
                        if call.as_array().and_then(|args| args.first()).and_then(integer) == Some(1) {
                            let blank = blank_row(self.columns);
                            self.rows.iter_mut().for_each(|row| *row = blank.clone());
                            self.changed = true;
                        }
                    }
                }
                "hl_attr_define" => calls.iter().for_each(|call| self.define_highlight(call)),
                "default_colors_set" => calls.iter().for_each(|call| self.set_defaults(call)),
                "mode_info_set" => calls.iter().for_each(|call| self.set_modes(call)),
                "mode_change" => {
                    for call in calls {
                        if let Some(index) = call.as_array().and_then(|args| args.get(1)).and_then(integer) {
                            self.mode = index.max(0) as usize;
                            self.changed = true;
                        }
                    }
                }
                "busy_start" => {
                    self.busy = true;
                    self.changed = true;
                }
                "busy_stop" => {
                    self.busy = false;
                    self.changed = true;
                }
                "flush" => {
                    if self.changed {
                        self.publish();
                        published += 1;
                    }
                }
                _ => {}
            }
        }
        published
    }

    fn publish(&mut self) {
        self.changed = false;
        self.published = Screen {
            columns: self.columns,
            rows: self.rows.clone(),
            cursor: (self.cursor.0.min(self.rows.len() - 1), self.cursor.1.min(self.columns - 1)),
            mode: self.mode,
            modes: self.modes.clone(),
            highlights: self.highlights.clone(),
            defaults: self.defaults,
            busy: self.busy,
            style_epoch: self.style_epoch,
            generation: self.published.generation + 1,
            scrolls: std::mem::take(&mut self.scrolls),
        };
    }

    fn resize(&mut self, width: i64, height: i64) {
        if width <= 0 || height <= 0 || width as usize > MAX_DIMENSION || height as usize > MAX_DIMENSION {
            return;
        }
        self.columns = width as usize;
        self.rows = (0..height as usize).map(|_| blank_row(self.columns)).collect();
        self.scrolls.clear();
        self.changed = true;
    }

    fn grid_line(&mut self, call: &Value) {
        let Some([grid, row, column, cells, ..]) = call.as_array().map(Vec::as_slice) else { return };
        let (Some(1), Some(row), Some(mut column), Some(cells)) = (integer(grid), integer(row), integer(column), cells.as_array()) else { return };
        if row < 0 || row as usize >= self.rows.len() || column < 0 || column as usize > self.columns {
            return;
        }
        let columns = self.columns as i64;
        let line = Arc::make_mut(&mut self.rows[row as usize]);
        let mut highlight = 0u32;
        for cell in cells {
            let Some(fields) = cell.as_array() else { continue };
            let Some(text) = fields.first().and_then(Value::as_str) else { continue };
            // An omitted highlight repeats the previous cell's.
            if let Some(id) = fields.get(1).and_then(integer) {
                highlight = id.max(0) as u32;
            }
            let repeats = fields.get(2).and_then(integer).unwrap_or(1);
            if repeats <= 0 {
                continue;
            }
            let value = Cell { text: Text::from_str(text), highlight };
            let end = (column + repeats).min(columns);
            for x in column..end {
                line[x as usize] = value.clone();
            }
            column = end;
        }
        self.changed = true;
    }

    fn grid_scroll(&mut self, call: &Value) {
        let Some([grid, top, bottom, left, right, amount, ..]) = call.as_array().map(Vec::as_slice) else { return };
        let (Some(1), Some(top), Some(bottom), Some(left), Some(right), Some(amount)) = (integer(grid), integer(top), integer(bottom), integer(left), integer(right), integer(amount)) else {
            return;
        };
        let (row_count, columns) = (self.rows.len() as i64, self.columns as i64);
        if top < 0 || bottom > row_count || top >= bottom || left < 0 || right > columns || left >= right || amount == 0 {
            return;
        }
        let full = left == 0 && right == columns;
        let mut copy = |rows: &mut Vec<Row>, destination: i64, source: i64| {
            if full {
                rows[destination as usize] = rows[source as usize].clone();
            } else {
                let origin = rows[source as usize].clone();
                let line = Arc::make_mut(&mut rows[destination as usize]);
                line[left as usize..right as usize].clone_from_slice(&origin[left as usize..right as usize]);
            }
        };
        if amount > 0 {
            for row in top..(bottom - amount).max(top) {
                copy(&mut self.rows, row, row + amount);
            }
        } else {
            let mut row = bottom - 1;
            while row >= top - amount {
                copy(&mut self.rows, row, row + amount);
                row -= 1;
            }
        }
        if full {
            if self.scrolls.len() >= 64 {
                // Bounded; the rows are still authoritative.
                self.scrolls.clear();
            } else {
                self.scrolls.push(Scroll { top: top as usize, bottom: bottom as usize, lines: amount });
            }
        }
        self.changed = true;
    }

    fn define_highlight(&mut self, call: &Value) {
        let Some([id, attributes, ..]) = call.as_array().map(Vec::as_slice) else { return };
        let Some(id) = integer(id).filter(|id| *id >= 0) else { return };
        let color = |key: &str| lookup(attributes, key).and_then(integer).map(|value| value as u32 & 0xffffff);
        let flag = |key: &str| lookup(attributes, key).and_then(Value::as_bool).unwrap_or(false);
        let mut highlight = Highlight {
            foreground: color("foreground"),
            background: color("background"),
            special: color("special"),
            reverse: flag("reverse"),
            italic: flag("italic"),
            bold: flag("bold"),
            strikethrough: flag("strikethrough"),
            underline: Underline::None,
        };
        for (key, kind) in [("underline", Underline::Line), ("undercurl", Underline::Curl), ("underdouble", Underline::Double), ("underdotted", Underline::Dotted), ("underdashed", Underline::Dashed)] {
            if flag(key) {
                highlight.underline = kind;
            }
        }
        let id = id as u32;
        match self.highlights.get(&id) {
            Some(existing) if *existing == highlight => return,
            Some(_) => self.style_epoch += 1,
            None => {}
        }
        Arc::make_mut(&mut self.highlights).insert(id, highlight);
        self.changed = true;
    }

    fn set_defaults(&mut self, call: &Value) {
        let Some([foreground, background, special, ..]) = call.as_array().map(Vec::as_slice) else { return };
        let color = |value: &Value| integer(value).filter(|v| *v >= 0).map(|v| v as u32 & 0xffffff);
        let mut next = self.defaults;
        if let Some(value) = color(foreground) {
            next.foreground = value;
        }
        if let Some(value) = color(background) {
            next.background = value;
        }
        next.special = color(special);
        if next != self.defaults {
            self.defaults = next;
            self.style_epoch += 1;
            self.changed = true;
        }
    }

    fn set_modes(&mut self, call: &Value) {
        let Some(modes) = call.as_array().and_then(|args| args.get(1)).and_then(Value::as_array) else { return };
        let modes = modes
            .iter()
            .map(|mode| ModeInfo {
                shape: match lookup(mode, "cursor_shape").and_then(Value::as_str) {
                    Some("horizontal") => CursorShape::Horizontal,
                    Some("vertical") => CursorShape::Vertical,
                    _ => CursorShape::Block,
                },
                blinks: lookup(mode, "blinkon").and_then(integer).unwrap_or(0) > 0 && lookup(mode, "blinkoff").and_then(integer).unwrap_or(0) > 0,
                name: lookup(mode, "name").and_then(Value::as_str).unwrap_or("").to_string(),
            })
            .collect();
        self.modes = Arc::new(modes);
        self.changed = true;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(name: &str, calls: Vec<Value>) -> Value {
        let mut items = vec![Value::from(name)];
        items.extend(calls);
        Value::Array(items)
    }

    fn cell(text: &str, highlight: Option<i64>, repeat: Option<i64>) -> Value {
        let mut fields = vec![Value::from(text)];
        if let Some(highlight) = highlight {
            fields.push(Value::from(highlight));
        }
        if let Some(repeat) = repeat {
            fields.push(Value::from(repeat));
        }
        Value::Array(fields)
    }

    fn line(row: i64, column: i64, cells: Vec<Value>) -> Value {
        event("grid_line", vec![Value::Array(vec![Value::from(1), Value::from(row), Value::from(column), Value::Array(cells)])])
    }

    fn scroll(top: i64, bottom: i64, left: i64, right: i64, lines: i64) -> Value {
        event("grid_scroll", vec![Value::Array(vec![1.into(), top.into(), bottom.into(), left.into(), right.into(), lines.into(), 0.into()])])
    }

    fn flush() -> Value {
        event("flush", vec![])
    }

    fn text_line(row: i64, text: &str) -> Value {
        line(row, 0, text.chars().map(|c| cell(&c.to_string(), Some(0), None)).collect())
    }

    fn numbered(model: &mut GridModel, rows: i64) {
        let mut events: Vec<Value> = (0..rows).map(|row| text_line(row, &format!("row{row}"))).collect();
        events.push(flush());
        model.apply(&events);
    }

    #[test]
    fn nothing_is_visible_before_flush() {
        let mut model = GridModel::new(10, 3);
        assert_eq!(model.apply(&[text_line(0, "hello")]), 0);
        assert_eq!(model.screen().row_text(0), "          ");
        assert_eq!(model.apply(&[flush()]), 1);
        assert_eq!(model.screen().row_text(0), "hello     ");
        assert_eq!(model.screen().generation, 1);
        // A flush with nothing new publishes nothing.
        assert_eq!(model.apply(&[flush()]), 0);
        assert_eq!(model.screen().generation, 1);
    }

    #[test]
    fn omitted_highlights_repeat_and_repeats_fill() {
        let mut model = GridModel::new(12, 2);
        model.apply(&[line(0, 1, vec![cell("a", Some(5), None), cell("b", None, None), cell("-", Some(7), Some(4)), cell("c", None, None)]), flush()]);
        let screen = model.screen();
        assert_eq!(screen.row_text(0), " ab----c    ");
        let highlights: Vec<u32> = screen.rows[0].iter().map(|cell| cell.highlight).collect();
        assert_eq!(highlights, vec![0, 5, 5, 7, 7, 7, 7, 7, 0, 0, 0, 0]);
    }

    #[test]
    fn wide_cells_keep_their_continuation() {
        let mut model = GridModel::new(6, 1);
        model.apply(&[line(0, 0, vec![cell("日", Some(1), None), cell("", None, None), cell("e\u{301}", None, None)]), flush()]);
        let row = &model.screen().rows[0];
        assert_eq!(row[0].text, Text::Char('日'));
        assert!(row[1].text.is_continuation());
        assert_eq!(row[2].text, Text::Cluster(Arc::from("e\u{301}")));
    }

    #[test]
    fn writes_past_the_edge_are_clipped() {
        let mut model = GridModel::new(4, 1);
        model.apply(&[line(0, 2, vec![cell("x", Some(0), Some(100))]), line(5, 0, vec![cell("y", Some(0), None)]), flush()]);
        assert_eq!(model.screen().row_text(0), "  xx");
    }

    #[test]
    fn full_scrolls_move_rows_and_keep_their_identity() {
        let mut model = GridModel::new(8, 5);
        numbered(&mut model, 5);
        let before = model.screen().rows.clone();
        model.apply(&[scroll(0, 5, 0, 8, 2), text_line(3, "new3"), text_line(4, "new4"), flush()]);
        let screen = model.screen();
        assert_eq!((0..5).map(|row| screen.row_text(row).trim_end().to_string()).collect::<Vec<_>>(), ["row2", "row3", "row4", "new3", "new4"]);
        assert!(Arc::ptr_eq(&screen.rows[0], &before[2]), "a row that only moved is the same row");
        assert_eq!(screen.scrolls, vec![Scroll { top: 0, bottom: 5, lines: 2 }]);
        // Down again, inside a region.
        model.apply(&[scroll(1, 4, 0, 8, -1), text_line(1, "top     "), flush()]);
        let screen = model.screen();
        assert_eq!((0..5).map(|row| screen.row_text(row).trim_end().to_string()).collect::<Vec<_>>(), ["row2", "top", "row3", "row4", "new4"]);
        assert_eq!(screen.scrolls, vec![Scroll { top: 1, bottom: 4, lines: -1 }]);
    }

    #[test]
    fn partial_width_scrolls_move_only_their_columns() {
        let mut model = GridModel::new(6, 3);
        model.apply(&[text_line(0, "aaaaaa"), text_line(1, "bbbbbb"), text_line(2, "cccccc"), flush()]);
        model.apply(&[scroll(0, 3, 2, 4, 1), flush()]);
        let screen = model.screen();
        assert_eq!(screen.row_text(0), "aabbaa");
        assert_eq!(screen.row_text(1), "bbccbb");
        assert_eq!(screen.row_text(2), "cccccc");
        assert!(screen.scrolls.is_empty(), "only full-width scrolls are reported");
    }

    #[test]
    fn redefining_a_highlight_starts_a_new_style_epoch() {
        let mut model = GridModel::new(4, 1);
        let define = |id: i64, foreground: i64, bold: bool| {
            event("hl_attr_define", vec![Value::Array(vec![id.into(), Value::Map(vec![("foreground".into(), foreground.into()), ("bold".into(), bold.into()), ("undercurl".into(), true.into())]), Value::Map(vec![]), Value::Array(vec![])])])
        };
        model.apply(&[define(3, 0xff0000, true), flush()]);
        let screen = model.screen();
        assert_eq!(screen.style_epoch, 0, "a new id changes nothing already drawn");
        assert_eq!(screen.highlight(3), Highlight { foreground: Some(0xff0000), bold: true, underline: Underline::Curl, ..Highlight::default() });
        assert_eq!(model.apply(&[define(3, 0xff0000, true), flush()]), 0, "the same definition is not a change");
        model.apply(&[define(3, 0x00ff00, false), flush()]);
        assert_eq!(model.screen().style_epoch, 1);
        model.apply(&[event("default_colors_set", vec![Value::Array(vec![0xffffff.into(), 0x000000.into(), (-1).into(), 0.into(), 0.into()])]), flush()]);
        let screen = model.screen();
        assert_eq!(screen.style_epoch, 2);
        assert_eq!(screen.defaults, Defaults { foreground: 0xffffff, background: 0, special: None });
    }

    #[test]
    fn resize_clear_cursor_and_modes() {
        let mut model = GridModel::new(4, 2);
        numbered(&mut model, 2);
        model.apply(&[
            event("grid_resize", vec![Value::Array(vec![1.into(), 6.into(), 3.into()])]),
            text_line(2, "abc"),
            event("grid_cursor_goto", vec![Value::Array(vec![1.into(), 2.into(), 3.into()])]),
            event(
                "mode_info_set",
                vec![Value::Array(vec![
                    true.into(),
                    Value::Array(vec![
                        Value::Map(vec![("name".into(), "normal".into()), ("cursor_shape".into(), "block".into())]),
                        Value::Map(vec![("name".into(), "insert".into()), ("cursor_shape".into(), "vertical".into()), ("blinkon".into(), 500.into()), ("blinkoff".into(), 500.into())]),
                    ]),
                ])],
            ),
            event("mode_change", vec![Value::Array(vec!["insert".into(), 1.into()])]),
            flush(),
        ]);
        let screen = model.screen();
        assert_eq!((screen.columns, screen.rows.len()), (6, 3));
        assert_eq!(screen.row_text(0), "      ", "a resize clears");
        assert_eq!(screen.row_text(2), "abc   ");
        assert_eq!(screen.cursor, (2, 3));
        assert_eq!(screen.cursor_shape(), CursorShape::Vertical);
        assert!(screen.modes[1].blinks);
        model.apply(&[event("grid_clear", vec![Value::Array(vec![1.into()])]), flush()]);
        assert_eq!(model.screen().row_text(2), "      ");
        // Events for other grids and absurd sizes are ignored.
        model.apply(&[event("grid_resize", vec![Value::Array(vec![2.into(), 9.into(), 9.into()])]), event("grid_resize", vec![Value::Array(vec![1.into(), 100000.into(), 2.into()])]), flush()]);
        assert_eq!((model.screen().columns, model.screen().rows.len()), (6, 3));
    }
}
