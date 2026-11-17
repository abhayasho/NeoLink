//! Against a real Neovim (skipped when `nvim` is not installed): the editor configuration loads, a UI
//! attaches, buffers open, and the screen shown after a selection notice is that buffer's.

use neolink_nvim::client::{Client, FileSignature};
use rmpv::Value;
use serde_json::json;
use std::path::PathBuf;
use std::time::{Duration, Instant};

fn nvim() -> Option<PathBuf> {
    let found = std::env::var_os("PATH")?.to_str()?.split(if cfg!(windows) { ';' } else { ':' }).map(|directory| PathBuf::from(directory).join(if cfg!(windows) { "nvim.exe" } else { "nvim" })).find(|path| path.is_file());
    if found.is_none() {
        eprintln!("nvim is not installed: skipping");
    }
    found
}

fn config() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../Resources/Editor/neolink.lua")
}

fn wait_for(client: &Client, what: &str, mut done: impl FnMut(&Client) -> bool) {
    let start = Instant::now();
    while !done(client) {
        assert!(start.elapsed() < Duration::from_secs(10), "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(2));
    }
}

fn screen_text(client: &Client) -> String {
    let screen = client.screen();
    (0..screen.rows.len()).map(|row| screen.row_text(row)).collect::<Vec<_>>().join("\n")
}

struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Scratch {
        let directory = std::env::temp_dir().join(format!("neolink-nvim-test-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).unwrap();
        // The spelling Neovim itself reports (no `\\?\` prefix on Windows).
        Scratch(neolink_core::paths::canonical(&directory))
    }

    fn file(&self, name: &str, contents: &str) -> String {
        let path = self.0.join(name);
        std::fs::write(&path, contents).unwrap();
        path.to_str().unwrap().to_string()
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn opens_types_and_saves() {
    let Some(nvim) = nvim() else { return };
    let scratch = Scratch::new("edit");
    let path = scratch.file("hello.txt", "first line\nsecond line\n");
    let client = Client::spawn(&nvim, &config(), 80, 24, || {}).expect("neovim starts");
    client.dispatch_wait(&json!({"method": "open", "path": path, "selection": 1}), Duration::from_secs(10)).expect("open");
    wait_for(&client, "the buffer on screen", |client| screen_text(client).contains("first line"));
    assert_eq!(client.with_state(|state| state.selection.clone()).map(|selection| (selection.0, selection.1)), Some((1, path.clone())));
    // `open` leaves the editor in insert mode: typing inserts.
    client.input("typed <lt>here> ").unwrap();
    wait_for(&client, "the typed text", |client| screen_text(client).contains("typed <here> first line"));
    wait_for(&client, "the unsaved-changes notice", |client| client.with_state(|state| state.modified.contains(&path)));
    let reply = client.dispatch_wait(&json!({"method": "save", "path": path}), Duration::from_secs(10)).expect("save");
    assert_eq!(reply["state"]["buffers"][0]["modified"], json!(false));
    wait_for(&client, "the saved notice", |client| client.with_state(|state| !state.modified.contains(&path)));
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "typed <here> first line\nsecond line\n");
    // A file changed behind the editor's back is not overwritten.
    client.input("more ").unwrap();
    std::thread::sleep(Duration::from_millis(1100));
    std::fs::write(&path, "changed outside\n").unwrap();
    let refused = client.dispatch_wait(&json!({"method": "save", "path": path}), Duration::from_secs(10));
    assert!(matches!(&refused, Err(error) if error.to_string().contains("changed outside")), "{refused:?}");
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "changed outside\n");
}

#[test]
fn every_selection_notice_is_followed_only_by_that_buffer() {
    let Some(nvim) = nvim() else { return };
    let scratch = Scratch::new("switch");
    let a = scratch.file("a.txt", &"alpha alpha alpha\n".repeat(30));
    let b = scratch.file("b.txt", &"bravo bravo bravo\n".repeat(30));
    let client = Client::spawn(&nvim, &config(), 60, 20, || {}).expect("neovim starts");
    for token in 1..=40u64 {
        let (path, own, other) = if token % 2 == 1 { (&a, "alpha", "bravo") } else { (&b, "bravo", "alpha") };
        // Not waiting for the reply: the notice alone must be enough.
        let _reply = client.dispatch(&json!({"method": "open", "path": path, "selection": token})).unwrap();
        wait_for(&client, "the selection notice", |client| client.with_state(|state| state.selection.as_ref().map(|selection| selection.0)) == Some(token));
        // The screen at the moment the notice has been read.
        let (text, selection) = client.with_state(|state| ((0..state.screen.rows.len()).map(|row| state.screen.row_text(row)).collect::<Vec<_>>().join("\n"), state.selection.clone().unwrap()));
        assert_eq!(&selection.1, path);
        assert!(text.contains(own), "switch {token}: the screen does not show {own}");
        assert!(!text.contains(other), "switch {token}: the screen still shows {other}");
    }
}

#[test]
fn keys_sent_right_after_a_switch_reach_the_new_buffer() {
    let Some(nvim) = nvim() else { return };
    let scratch = Scratch::new("order");
    let a = scratch.file("a.txt", "A\n");
    let b = scratch.file("b.txt", "B\n");
    let client = Client::spawn(&nvim, &config(), 60, 20, || {}).expect("neovim starts");
    client.dispatch_wait(&json!({"method": "open", "path": a, "selection": 1}), Duration::from_secs(10)).unwrap();
    for round in 0..10u64 {
        // Switch and type without waiting for anything.
        let (path, word) = if round % 2 == 0 { (&b, "b") } else { (&a, "a") };
        let _reply = client.open(path, None, 2 + round).unwrap();
        client.input(&format!("{word}{round} ")).unwrap();
    }
    wait_for(&client, "the typed text", |client| screen_text(client).contains("a9 "));
    client.dispatch_wait(&json!({"method": "save", "path": a}), Duration::from_secs(10)).unwrap();
    client.dispatch_wait(&json!({"method": "save", "path": b}), Duration::from_secs(10)).unwrap();
    let (in_a, in_b) = (std::fs::read_to_string(&a).unwrap(), std::fs::read_to_string(&b).unwrap());
    assert!(!in_a.contains('b') && !in_b.contains('a'), "keys reached the wrong buffer: a = {in_a:?}, b = {in_b:?}");
    for round in 0..10u64 {
        let (text, word) = if round % 2 == 0 { (&in_b, "b") } else { (&in_a, "a") };
        assert!(text.contains(&format!("{word}{round} ")), "round {round} is missing: a = {in_a:?}, b = {in_b:?}");
    }
}

#[test]
fn open_with_and_without_a_line() {
    let Some(nvim) = nvim() else { return };
    let scratch = Scratch::new("line");
    let path = scratch.file("lines.txt", &(1..=200).map(|n| format!("line {n}\n")).collect::<String>());
    let client = Client::spawn(&nvim, &config(), 60, 20, || {}).expect("neovim starts");
    let reply = client.open(&path, None, 1).unwrap().recv_timeout(Duration::from_secs(10)).unwrap().unwrap();
    assert!(reply.as_str().unwrap().contains("\"ok\":true"), "{reply}");
    wait_for(&client, "the top of the file", |client| screen_text(client).contains("line 1 "));
    let other = scratch.file("other.txt", "other\n");
    client.open(&other, None, 2).unwrap().recv_timeout(Duration::from_secs(10)).unwrap().unwrap();
    client.open(&path, Some(150), 3).unwrap().recv_timeout(Duration::from_secs(10)).unwrap().unwrap();
    wait_for(&client, "line 150", |client| screen_text(client).contains("line 150"));
}

#[test]
fn resizing_republishes_the_whole_screen_at_the_new_size() {
    let Some(nvim) = nvim() else { return };
    let scratch = Scratch::new("resize");
    let path = scratch.file("wide.txt", &format!("{}\n", "0123456789".repeat(12)));
    let client = Client::spawn(&nvim, &config(), 40, 10, || {}).expect("neovim starts");
    client.dispatch_wait(&json!({"method": "open", "path": path, "selection": 1}), Duration::from_secs(10)).unwrap();
    for (columns, rows) in [(100usize, 30usize), (50, 12), (120, 40)] {
        client.resize(columns, rows).unwrap();
        wait_for(&client, "the resized screen", |client| {
            let screen = client.screen();
            (screen.columns, screen.rows.len()) == (columns, rows) && screen.rows.iter().all(|row| row.len() == columns)
        });
    }
    assert!(screen_text(&client).contains("0123456789012345678901234567890123456789"));
}

fn select(client: &Client, path: &str, token: u64) {
    let _reply = client.open(path, None, token).unwrap();
    wait_for(client, "the selection notice", |client| client.with_state(|state| state.selection.as_ref().map(|selection| selection.0)) == Some(token));
}

fn rows(client: &Client) -> Vec<String> {
    let screen = client.screen();
    (0..screen.rows.len()).map(|row| screen.row_text(row)).collect()
}

#[test]
fn a_remembered_screen_is_exactly_what_neovim_redraws() {
    let Some(nvim) = nvim() else { return };
    let scratch = Scratch::new("remember");
    let a = scratch.file("a.txt", &(1..=300).map(|n| format!("alpha {n}\n")).collect::<String>());
    let b = scratch.file("b.txt", &(1..=300).map(|n| format!("bravo {n}\n")).collect::<String>());
    let client = Client::spawn(&nvim, &config(), 70, 24, || {}).expect("neovim starts");
    select(&client, &a, 1);
    assert!(client.take_left(&a).is_none(), "a buffer that is on screen has no remembered screen");
    let mut token = 1;
    // Leave the buffer at the top, after cursor moves, after paging, and at its end.
    for keys in ["", "<Down><Down><Right>", "<PageDown><PageDown>", "<C-End>", "typed text<CR>"] {
        if !keys.is_empty() {
            client.input(keys).unwrap();
            std::thread::sleep(Duration::from_millis(150));
        }
        token += 1;
        select(&client, &b, token);
        let left = client.take_left(&a).expect("the screen of the buffer that was left");
        assert!(left.plain_insert, "left in insert mode without a popup menu");
        let remembered: Vec<String> = (0..left.screen.rows.len()).map(|row| left.screen.row_text(row)).collect();
        assert!(remembered.iter().any(|row| row.contains("alpha")) && !remembered.iter().any(|row| row.contains("bravo")));
        token += 1;
        select(&client, &a, token);
        // Let Neovim finish anything it draws after the notice.
        std::thread::sleep(Duration::from_millis(100));
        let confirmed = client.screen();
        assert_eq!(rows(&client), remembered, "after {keys:?}: Neovim redrew something different from what was remembered");
        assert_eq!(confirmed.cursor, left.screen.cursor, "after {keys:?}: the cursor moved");
        assert_eq!(confirmed.cursor_shape(), left.screen.cursor_shape());
    }
}

#[test]
fn a_hidden_buffer_that_changes_loses_its_remembered_screen() {
    let Some(nvim) = nvim() else { return };
    let scratch = Scratch::new("touch");
    let a = scratch.file("a.txt", "alpha\n");
    let b = scratch.file("b.txt", "bravo\n");
    let client = Client::spawn(&nvim, &config(), 60, 20, || {}).expect("neovim starts");
    select(&client, &a, 1);
    select(&client, &b, 2);
    wait_for(&client, "the remembered screen", |client| client.with_state(|state| state.left.iter().any(|entry| entry.0 == a)));
    // Something edits the hidden buffer (a language server, an agent through the editor).
    client
        .call("nvim_exec_lua", vec![Value::from("local path = ...; for _, buf in ipairs(vim.api.nvim_list_bufs()) do if vim.api.nvim_buf_get_name(buf) == path then vim.api.nvim_buf_set_lines(buf, 0, 0, false, {'changed while hidden'}) end end return true"), Value::Array(vec![Value::from(a.as_str())])], Duration::from_secs(10))
        .unwrap();
    wait_for(&client, "the touch notice", |client| client.with_state(|state| state.touched.iter().any(|path| path == &a)));
    assert!(client.take_left(&a).is_none(), "the remembered screen survived a change to its buffer");

    // Leaving a buffer in normal mode is remembered as such: `open` returns to insert mode, so that
    // screen (block cursor) is not what will be drawn.
    select(&client, &a, 3);
    client.input("<Esc>").unwrap();
    std::thread::sleep(Duration::from_millis(150));
    select(&client, &b, 4);
    let left = client.take_left(&a).expect("remembered");
    assert!(!left.plain_insert);

    // A file rewritten on disk no longer has the signature it was remembered with.
    let before = FileSignature::of(&b).unwrap();
    std::thread::sleep(Duration::from_millis(1100));
    std::fs::write(&b, "rewritten by something else\n").unwrap();
    assert_ne!(FileSignature::of(&b).unwrap(), before);
    assert!(FileSignature::of(&scratch.0.join("missing.txt").to_string_lossy()).is_none());
}

#[test]
fn horizontal_answers_keep_their_exact_redraw_and_obey_selection_order() {
    let Some(nvim) = nvim() else { return };
    let scratch = Scratch::new("horizontal");
    let line = "abcdefghijklmnopqrstuvwxyz0123456789".repeat(20);
    let a = scratch.file("a.txt", &(line.clone() + "\n").repeat(30));
    let b = scratch.file("b.txt", &("BRAVO_".repeat(120) + "\n").repeat(30));
    let client = Client::spawn(&nvim, &config(), 80, 24, || {}).unwrap();
    client.open(&a, None, 1).unwrap();
    wait_for(&client, "first selection", |c| c.with_state(|s| s.selection.as_ref().map(|s| s.0)) == Some(1));
    for (token, column) in [(10, 24), (11, 48), (12, 7), (13, 0)] {
        client.horizontal_scroll(token, 0, 12, column, false).unwrap();
        wait_for(&client, "horizontal acknowledgement", |c| c.with_state(|s| s.horizontal.as_ref().map(|a| a.token)) == Some(token));
        let answer = client.with_state(|s| s.horizontal.clone().unwrap());
        assert_eq!(answer.after, column as u64);
        assert_eq!(answer.width, 80);
        assert_eq!(answer.height, 23);
        let row = answer.screen.row_text(0);
        // Ignore Neovim's optional listchars precedes marker in the very first text cell.
        let cells: Vec<char> = row.chars().skip(answer.gutter + 1).take(20).collect();
        let expected: Vec<char> = line.chars().skip(column as usize + 1).take(20).collect();
        assert_eq!(cells, expected, "token={token} row={row}");
        // The acknowledgement owns immutable rows even as a later redraw arrives.
        client.notify("nvim_command", vec![Value::from("redraw!")]).unwrap();
        assert_eq!(answer.screen.row_text(0), row);
    }
    // A scroll immediately following a switch must target the newly selected file.
    client.open(&b, None, 2).unwrap();
    client.horizontal_scroll(20, 0, 12, 18, false).unwrap();
    wait_for(&client, "scroll after selection", |c| c.with_state(|s| s.horizontal.as_ref().map(|a| a.token)) == Some(20));
    let answer = client.with_state(|s| s.horizontal.clone().unwrap());
    assert!(answer.screen.row_text(0).contains("BRAVO_"));
    assert!(!answer.screen.row_text(0).contains("abcdef"));
    assert_eq!(answer.after, 18);
}

#[test]
fn horizontal_flush_fallback_and_split_eligibility() {
    let Some(nvim) = nvim() else { return };
    let scratch = Scratch::new("horizontal-fallback");
    let path = scratch.file("long.txt", &("abcdefghij".repeat(100) + "\n").repeat(30));
    let client = Client::spawn(&nvim, &config(), 80, 24, || {}).unwrap();
    client.open(&path, None, 1).unwrap();
    wait_for(&client, "single unwrapped window", |c| c.with_state(|s| s.horizontal_allowed));
    client.call("nvim_exec_lua", vec![Value::from("vim.api.nvim__redraw = nil"), Value::Array(vec![])], Duration::from_secs(5)).unwrap();
    client.horizontal_scroll(30, 0, 10, 17, false).unwrap();
    wait_for(&client, "fallback redraw", |c| c.with_state(|s| s.horizontal.as_ref().map(|a| a.token)) == Some(30));
    assert_eq!(client.with_state(|s| s.horizontal.as_ref().unwrap().after), 17);
    client.call("nvim_command", vec![Value::from("setlocal wrap")], Duration::from_secs(5)).unwrap();
    wait_for(&client, "wrapped window uses fallback", |c| c.with_state(|s| !s.horizontal_allowed));
    client.call("nvim_command", vec![Value::from("setlocal nowrap | split")], Duration::from_secs(5)).unwrap();
    wait_for(&client, "split uses fallback", |c| c.with_state(|s| !s.horizontal_allowed));
}
