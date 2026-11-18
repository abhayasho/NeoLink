//! Crash reports. A panic on any thread writes a plain-text report (version, system, thread, message,
//! place and backtrace) to the logs folder before Rust's own handler runs; the next launch says that
//! the app quit unexpectedly and where the report is. Nothing is sent anywhere.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Reports kept; older ones are removed when a new one is written.
const KEPT: usize = 20;
/// Names the newest report the user has been told about.
const SEEN: &str = "last-reported";

/// Where reports go: `~/Library/Logs/NeoLink` on macOS, `%LOCALAPPDATA%\NeoLink\Logs` on Windows,
/// `$XDG_STATE_HOME/neolink` (or `~/.local/state/neolink`) elsewhere. `NEOLINK_LOG_DIR` overrides it.
pub fn folder() -> Option<PathBuf> {
    if let Some(folder) = std::env::var_os("NEOLINK_LOG_DIR").filter(|folder| !folder.is_empty()) {
        return Some(PathBuf::from(folder));
    }
    if cfg!(target_os = "macos") {
        return neolink_core::paths::home().map(|home| home.join("Library/Logs/NeoLink"));
    }
    if cfg!(windows) {
        return std::env::var_os("LOCALAPPDATA").map(|local| PathBuf::from(local).join("NeoLink").join("Logs"));
    }
    std::env::var_os("XDG_STATE_HOME").map(PathBuf::from).or_else(|| neolink_core::paths::home().map(|home| home.join(".local/state"))).map(|state| state.join("neolink"))
}

/// Installs the panic hook (once, at startup).
pub fn install() {
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        if let Some(folder) = folder() {
            let message = match (info.payload().downcast_ref::<&str>(), info.payload().downcast_ref::<String>()) {
                (Some(text), _) => text.to_string(),
                (_, Some(text)) => text.clone(),
                _ => "(no message)".to_string(),
            };
            let place = info.location().map(|place| format!("{}:{}:{}", place.file(), place.line(), place.column())).unwrap_or_else(|| "unknown".into());
            let thread = std::thread::current().name().unwrap_or("unnamed").to_string();
            let backtrace = std::backtrace::Backtrace::force_capture().to_string();
            let seconds = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |since| since.as_secs());
            if let Ok(path) = write_report(&folder, seconds, std::process::id(), &report(seconds, &thread, &message, &place, &backtrace)) {
                eprintln!("NeoLink crashed; a report was written to {}", path.display());
            }
        }
        previous(info);
    }));
}

fn report(seconds: u64, thread: &str, message: &str, place: &str, backtrace: &str) -> String {
    format!(
        "NeoLink {version} crash report\n\nTime:     {time} UTC\nSystem:   {os} {arch}\nThread:   {thread}\nMessage:  {message}\nLocation: {place}\n\nBacktrace:\n{backtrace}\n",
        version = env!("CARGO_PKG_VERSION"),
        time = utc(seconds),
        os = std::env::consts::OS,
        arch = std::env::consts::ARCH,
    )
}

/// Writes the report as `crash-<seconds>-<pid>.txt` (names sort by time) and keeps the newest `KEPT`.
fn write_report(folder: &Path, seconds: u64, pid: u32, text: &str) -> std::io::Result<PathBuf> {
    std::fs::create_dir_all(folder)?;
    let path = folder.join(format!("crash-{seconds:010}-{pid}.txt"));
    std::fs::File::create(&path)?.write_all(text.as_bytes())?;
    let mut reports = reports(folder);
    while reports.len() > KEPT {
        let _ = std::fs::remove_file(folder.join(reports.remove(0)));
    }
    Ok(path)
}

/// Report names, oldest first.
fn reports(folder: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(folder)
        .map(|entries| entries.filter_map(|entry| entry.ok()?.file_name().into_string().ok()).filter(|name| name.starts_with("crash-") && name.ends_with(".txt")).collect())
        .unwrap_or_default();
    names.sort();
    names
}

/// The newest report written since the user was last told about one, marked as told. `None` when
/// there is none (the first launch with reports from before marks them all as told).
pub fn take_unseen() -> Option<PathBuf> {
    take_unseen_in(&folder()?)
}

fn take_unseen_in(folder: &Path) -> Option<PathBuf> {
    let newest = reports(folder).pop()?;
    let seen = std::fs::read_to_string(folder.join(SEEN)).unwrap_or_default();
    if seen.trim() >= newest.as_str() {
        return None;
    }
    let _ = std::fs::write(folder.join(SEEN), &newest);
    Some(folder.join(newest))
}

/// `seconds` since 1970 as `YYYY-MM-DD HH:MM:SS` (UTC).
fn utc(seconds: u64) -> String {
    let (days, rest) = ((seconds / 86_400) as i64, seconds % 86_400);
    // Howard Hinnant's days-to-civil algorithm.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let day_of_era = z.rem_euclid(146_097);
    let year_of_era = (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 { month_index + 3 } else { month_index - 9 };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02} {:02}:{:02}:{:02}", rest / 3600, rest % 3600 / 60, rest % 60)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dates_are_utc_calendar_dates() {
        assert_eq!(utc(0), "1970-01-01 00:00:00");
        assert_eq!(utc(951_782_400), "2000-02-29 00:00:00");
        assert_eq!(utc(1_794_960_000 + 3_723), "2026-11-18 01:02:03");
    }

    #[test]
    fn reports_are_kept_bounded_and_announced_once() {
        let folder = std::env::temp_dir().join(format!("neolink-crash-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&folder);
        assert_eq!(take_unseen_in(&folder), None);
        for second in 0..(KEPT as u64 + 5) {
            write_report(&folder, 1_000 + second, 7, "report").unwrap();
        }
        let names = reports(&folder);
        assert_eq!(names.len(), KEPT);
        assert_eq!(names.first().map(String::as_str), Some("crash-0000001005-7.txt"), "the oldest are removed");
        let newest = take_unseen_in(&folder).expect("an unseen report");
        assert!(newest.ends_with("crash-0000001024-7.txt"));
        assert_eq!(take_unseen_in(&folder), None, "told only once");
        write_report(&folder, 2_000, 8, "report").unwrap();
        assert!(take_unseen_in(&folder).is_some_and(|path| path.ends_with("crash-0000002000-8.txt")));
        let text = report(0, "main", "boom", "src/x.rs:1:2", "trace");
        assert!(text.contains("Message:  boom") && text.contains(env!("CARGO_PKG_VERSION")));
        let _ = std::fs::remove_dir_all(&folder);
    }
}
