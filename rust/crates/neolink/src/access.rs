//! Accessibility through AccessKit: VoiceOver on macOS, Narrator and other UI Automation clients on
//! Windows. The workspace describes what is on screen (`Workspace::accessibility`); this turns that
//! into AccessKit's tree. Nothing is built unless a screen reader is listening.

use std::collections::{HashMap, HashSet};

use accesskit::{Action, Node, NodeId, Rect, Role, TreeId, TreeInfo, TreeUpdate};

use crate::workspace::AccessItem;

pub const ROOT: NodeId = NodeId(1);

/// A node id from an item's key: stable while the element exists, never the root's.
pub fn node_id(key: &str) -> NodeId {
    let mut hash: u64 = 0xcbf29ce484222325;
    for byte in key.bytes() {
        hash = (hash ^ byte as u64).wrapping_mul(0x100000001b3);
    }
    NodeId(hash | 2)
}

/// Roles that take the keyboard, so assistive technology may move focus to them.
fn focusable(role: Role) -> bool {
    matches!(role, Role::Terminal | Role::MultilineTextInput | Role::SearchInput | Role::Tab | Role::TreeItem | Role::Button)
}

/// The whole tree for `items` under a window named `title`.
pub fn tree(items: &[AccessItem], title: &str) -> TreeUpdate {
    let mut nodes: Vec<(NodeId, Node)> = Vec::with_capacity(items.len() + 1);
    let mut children: HashMap<NodeId, Vec<NodeId>> = HashMap::new();
    let mut seen: HashSet<NodeId> = HashSet::new();
    let keys: HashSet<&str> = items.iter().map(|item| item.key.as_str()).collect();
    let mut focus = ROOT;
    for item in items {
        let id = node_id(&item.key);
        if !seen.insert(id) {
            continue;
        }
        let mut node = Node::new(item.role);
        node.set_label(item.label.clone());
        if let Some(value) = &item.value {
            node.set_value(value.clone());
        }
        node.set_bounds(Rect { x0: item.rect.x as f64, y0: item.rect.y as f64, x1: item.rect.right() as f64, y1: item.rect.bottom() as f64 });
        if let Some(selected) = item.selected {
            node.set_selected(selected);
        }
        if let Some(expanded) = item.expanded {
            node.set_expanded(expanded);
            node.add_action(if expanded { Action::Collapse } else { Action::Expand });
        }
        if let Some(level) = item.level {
            node.set_level(level);
        }
        if item.read_only {
            node.set_read_only();
        }
        if item.press.is_some() {
            node.add_action(Action::Click);
            if focusable(item.role) {
                node.add_action(Action::Focus);
            }
        }
        if item.focused {
            focus = id;
        }
        // A parent that is not in this update would make the tree invalid: such items join the root.
        let parent = item.parent.as_deref().filter(|parent| keys.contains(parent)).map(node_id).unwrap_or(ROOT);
        children.entry(parent).or_default().push(id);
        nodes.push((id, node));
    }
    for (id, node) in nodes.iter_mut() {
        if let Some(list) = children.remove(id) {
            node.set_children(list);
        }
    }
    let mut root = Node::new(Role::Window);
    root.set_label(title.to_string());
    root.set_children(children.remove(&ROOT).unwrap_or_default());
    nodes.insert(0, (ROOT, root));
    TreeUpdate { nodes, tree: Some(TreeInfo::new(ROOT)), tree_id: TreeId::ROOT, focus }
}

/// Where a request to act on `node` should press, if it names an item that can be pressed.
pub fn press_point(items: &[AccessItem], node: NodeId) -> Option<(f32, f32)> {
    items.iter().find(|item| node_id(&item.key) == node).and_then(|item| item.press)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::render::Rect as Area;

    fn item(key: &str, parent: Option<&str>, role: Role) -> AccessItem {
        AccessItem { key: key.into(), parent: parent.map(Into::into), role, label: key.into(), value: None, rect: Area::new(0.0, 0.0, 10.0, 10.0), selected: None, expanded: None, level: None, read_only: false, focused: false, press: Some((5.0, 5.0)) }
    }

    #[test]
    fn every_node_has_one_parent_and_focus_is_reported() {
        let mut terminal = item("content:1", None, Role::Terminal);
        terminal.focused = true;
        terminal.value = Some("$ ls".into());
        let items = vec![item("tabs", None, Role::TabList), item("tab:1", Some("tabs"), Role::Tab), item("orphan", Some("missing"), Role::Button), terminal, item("tab:1", Some("tabs"), Role::Tab)];
        let update = tree(&items, "NeoLink");
        assert_eq!(update.focus, node_id("content:1"));
        // The duplicate key is dropped; root + 4 distinct items.
        assert_eq!(update.nodes.len(), 5);
        let mut parents: HashMap<NodeId, usize> = HashMap::new();
        for (_, node) in &update.nodes {
            for child in node.children() {
                *parents.entry(*child).or_default() += 1;
            }
        }
        for (id, _) in update.nodes.iter().skip(1) {
            assert_eq!(parents.get(id), Some(&1), "{id:?} has exactly one parent");
        }
        let root = &update.nodes[0].1;
        assert!(root.children().contains(&node_id("orphan")));
        assert_eq!(press_point(&items, node_id("tab:1")), Some((5.0, 5.0)));
        assert_ne!(node_id("a"), ROOT);
    }
}
