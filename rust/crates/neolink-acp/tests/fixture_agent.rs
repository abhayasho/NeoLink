//! The session against the repository's offline ACP peer (`scripts/fixtures/acp-agent.py`), as the Swift
//! app's ACP tests do. Skipped where `python3` is missing.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use neolink_acp::{Session, State};
use neolink_core::agent::CodingAgent;

fn python() -> Option<String> {
    let names: &[&str] = if cfg!(windows) { &["python.exe", "python3.exe"] } else { &["python3"] };
    std::env::split_paths(&std::env::var_os("PATH")?).flat_map(|directory| names.iter().map(move |name| directory.join(name))).find(|path| path.is_file()).map(|path| path.to_string_lossy().into_owned())
}

fn fixture() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../scripts/fixtures/acp-agent.py")
}

fn connected() -> Option<Session> {
    let python = python()?;
    let agent = CodingAgent { name: "Fixture".into(), executable: python.clone(), arguments: vec![fixture().to_string_lossy().into_owned()] };
    let session = Session::new(agent, &std::env::temp_dir().canonicalize().unwrap(), Vec::new(), || {});
    session.connect(Some(&python));
    wait(&session, "ready", |state| state.is_ready);
    Some(session)
}

fn wait(session: &Session, what: &str, done: impl Fn(&State) -> bool) -> State {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let state = session.state();
        if done(&state) {
            return state;
        }
        assert!(Instant::now() < deadline, "timed out waiting for {what}: status {:?}, error {:?}", state.status, state.error);
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn a_turn_streams_text_asks_permission_and_finishes() {
    let Some(session) = connected() else { return };
    let state = session.state();
    assert_eq!(state.status, "Ready");
    assert_eq!(state.current_mode, "ask");
    assert_eq!(state.modes.iter().map(|mode| mode.name.as_str()).collect::<Vec<_>>(), vec!["Ask", "Plan"]);
    assert!(session.send("hello", Some("/tmp/context.py")));
    let state = wait(&session, "a permission request", |state| !state.permissions.is_empty());
    assert_eq!(state.status, "Permission needed");
    assert_eq!(state.messages[0].role, "You");
    assert!(state.messages[0].text.ends_with("Context file (saved on disk): /tmp/context.py"));
    // Text split inside a UTF-8 character by the peer arrives whole.
    assert_eq!(state.messages[1].text, "Hello \u{4e16}\u{754c}. ");
    assert_eq!(state.messages[1].role, "Fixture");
    let permission = &state.permissions[0];
    assert_eq!(permission.title, "Preview a change");
    assert!(permission.details.contains("example.py"));
    assert_eq!(permission.options.iter().map(|option| option.name.as_str()).collect::<Vec<_>>(), vec!["Allow once", "Reject"]);
    // An option the request did not offer is ignored.
    session.answer(permission.id, Some("invented"));
    assert_eq!(session.state().permissions.len(), 1);
    session.answer(permission.id, Some("allow"));
    let state = wait(&session, "the end of the turn", |state| !state.is_busy);
    assert_eq!(state.status, "Ready");
    assert_eq!(state.turns_finished, 1);
    assert_eq!(state.tools[0].status, "completed");
    assert!(state.tools[0].details.contains("example.py\nBefore:\nbefore\nAfter:\nafter"));
    assert_eq!(state.messages.last().unwrap().text, "Approved.");
    session.close();
    assert_eq!(session.state().status, "Closed");
}

#[test]
fn stopping_a_turn_cancels_its_permission_request() {
    let Some(session) = connected() else { return };
    assert!(session.send("cancel", None));
    wait(&session, "a permission request", |state| !state.permissions.is_empty());
    // The peer asserts that the pending permission was cancelled before `session/cancel`.
    session.cancel();
    let state = wait(&session, "the turn to stop", |state| !state.is_busy);
    assert_eq!(state.status, "Stopped");
    assert!(state.permissions.is_empty() && state.error.is_none(), "{:?}", state.error);
    session.close();
}

#[test]
fn modes_change_and_a_lost_agent_is_reported() {
    let Some(session) = connected() else { return };
    session.set_mode("plan");
    wait(&session, "the mode", |state| state.current_mode == "plan" && !state.is_busy);
    session.set_mode("invented");
    assert_eq!(session.state().current_mode, "plan");
    assert!(session.send("disconnect", None));
    let state = wait(&session, "the disconnect", |state| state.status == "Disconnected");
    assert!(!state.is_ready && !state.is_busy);
    assert!(state.error.unwrap().starts_with("Agent disconnected."));
    assert!(!session.send("again", None));
}

#[test]
fn a_malformed_message_ends_the_conversation() {
    let Some(session) = connected() else { return };
    assert!(session.send("malformed", None));
    let state = wait(&session, "the failure", |state| state.status == "Disconnected");
    assert!(state.error.unwrap().starts_with("The agent sent a malformed protocol message."));
}

#[test]
fn a_missing_adapter_is_explained() {
    let session = Session::new(CodingAgent::claude_acp(), &std::env::temp_dir(), Vec::new(), || {});
    session.connect(None);
    let state = session.state();
    assert_eq!(state.status, "Could not connect");
    assert!(state.error.unwrap().starts_with("ACP executable not found."));
}
