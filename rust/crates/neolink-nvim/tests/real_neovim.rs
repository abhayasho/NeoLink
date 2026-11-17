//! Against a real Neovim (skipped when `nvim` is not installed): the editor configuration loads, a UI
//! attaches, buffers open, and the screen shown after a selection notice is that buffer's.

use neolink_nvim::client::Client;
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
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../Resources/Editor/neolink.lua")
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
