//! A popup menu drawn by the app's own renderer (the Swift app uses native menus here; the entries and
//! their order are the same, the look is not: PLAN.md).

use crate::chrome::Ui;
use crate::render::Rect;
use crate::theme;

/// What choosing an item does.
#[derive(Clone, Debug, PartialEq)]
pub enum Action {
    Editor(&'static str),
    TextSize(f32),
    TextSizeBy(f32),
    ToggleCompact,
    ToggleHidden,
    ToggleHideIgnored,
    ToggleReveal,
    NewFile,
    NewFolder,
    GitCreateBranch,
    GitSwitch(String),
    GitStash(Option<String>),
    Nothing,
}

#[derive(Clone, Debug)]
pub enum Item {
    Entry { label: String, action: Action, checked: bool, enabled: bool },
    Separator,
}

impl Item {
    pub fn entry(label: &str, action: Action) -> Item {
        Item::Entry { label: label.to_string(), action, checked: false, enabled: true }
    }

    pub fn toggle(label: &str, action: Action, checked: bool) -> Item {
        Item::Entry { label: label.to_string(), action, checked, enabled: true }
    }

    pub fn note(label: &str) -> Item {
        Item::Entry { label: label.to_string(), action: Action::Nothing, checked: false, enabled: false }
    }
}

pub struct Menu {
    pub items: Vec<Item>,
    /// The control it hangs from.
    pub anchor: Rect,
    rects: Vec<Rect>,
    frame: Rect,
    pub hover: Option<usize>,
}

impl Menu {
    pub fn new(anchor: Rect, items: Vec<Item>) -> Menu {
        Menu { items, anchor, rects: Vec::new(), frame: Rect::default(), hover: None }
    }

    pub fn item_rect(&self, index: usize) -> Option<Rect> {
        self.rects.get(index).copied()
    }

    pub fn contains(&self, x: f32, y: f32) -> bool {
        self.frame.contains(x, y)
    }

    /// Returns `true` if the highlighted item changed.
    pub fn pointer(&mut self, x: f32, y: f32) -> bool {
        let hover = self.rects.iter().position(|rect| rect.contains(x, y)).filter(|index| matches!(self.items[*index], Item::Entry { enabled: true, .. }));
        let changed = hover != self.hover;
        self.hover = hover;
        changed
    }

    /// The action under `(x, y)`, if an enabled item is there.
    pub fn action_at(&self, x: f32, y: f32) -> Option<Action> {
        let index = self.rects.iter().position(|rect| rect.contains(x, y))?;
        match &self.items[index] {
            Item::Entry { action, enabled: true, .. } => Some(action.clone()),
            _ => None,
        }
    }

    pub fn draw(&mut self, ui: &mut Ui, bounds: (f32, f32)) {
        let row = ui.px(24.0);
        let separator = ui.px(9.0);
        let pad = ui.px(6.0);
        let mut width = ui.px(160.0);
        for item in &self.items {
            if let Item::Entry { label, .. } = item {
                width = width.max(ui.measure(label, 12.0, 400, false) + ui.px(44.0));
            }
        }
        let height: f32 = self.items.iter().map(|item| if matches!(item, Item::Separator) { separator } else { row }).sum::<f32>() + 2.0 * pad;
        let x = self.anchor.x.min(bounds.0 - width - ui.px(4.0)).max(ui.px(4.0));
        let mut y = self.anchor.bottom() + ui.px(2.0);
        if y + height > bounds.1 {
            y = (self.anchor.y - height - ui.px(2.0)).max(ui.px(4.0));
        }
        self.frame = Rect::new(x, y, width, height);
        let line = ui.px(1.0).max(1.0);
        ui.shadow(self.frame, 7.0);
        ui.rounded(self.frame, 7.0, theme::rgb(0x262626));
        ui.outline(self.frame, 7.0, theme::white(0.14));
        let _ = line;
        self.rects.clear();
        let mut top = y + pad;
        for (index, item) in self.items.iter().enumerate() {
            match item {
                Item::Separator => {
                    self.rects.push(Rect::new(x, top, width, separator));
                    ui.painter.scene.fill(x + ui.px(8.0), top + separator * 0.5, width - ui.px(16.0), line, theme::white(0.1));
                    top += separator;
                }
                Item::Entry { label, checked, enabled, .. } => {
                    let rect = Rect::new(x, top, width, row);
                    self.rects.push(rect);
                    if self.hover == Some(index) {
                        ui.rounded(Rect::new(x + ui.px(5.0), top, width - ui.px(10.0), row), 4.0, theme::rgb(0x2F6FDB));
                    }
                    let middle = top + row * 0.5;
                    if *checked {
                        ui.text("\u{2713}", x + ui.px(10.0), middle, 11.0, 600, false, theme::TEXT_PRIMARY);
                    }
                    ui.text(label, x + ui.px(28.0), middle, 12.0, 400, false, if *enabled { theme::TEXT_PRIMARY } else { theme::TEXT_SECONDARY });
                    top += row;
                }
            }
        }
    }
}
