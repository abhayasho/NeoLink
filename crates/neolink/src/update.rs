//! Help → Check for Updates: asks GitHub for the latest release, only when chosen (NeoLink makes no
//! network connections on its own). It uses the system's `curl` (part of macOS and of Windows 10 and
//! later), so the app carries no HTTP or TLS code of its own.

const LATEST: &str = "https://api.github.com/repos/abhayasho/NeoLink/releases/latest";
pub const RELEASES: &str = "https://github.com/abhayasho/NeoLink/releases/latest";

/// What a check found.
#[derive(Clone, Debug, PartialEq)]
pub enum Found {
    /// A newer version (e.g. "2.2.0") and its release page.
    Newer(String, String),
    UpToDate,
    Failed(String),
}

/// Checks on its own thread and hands the answer to `done`.
pub fn check(done: impl FnOnce(Found) + Send + 'static) {
    let _ = std::thread::Builder::new().name("update-check".into()).spawn(move || done(fetch()));
}

fn fetch() -> Found {
    let output = std::process::Command::new(if cfg!(windows) { "curl.exe" } else { "curl" })
        .args(["--fail", "--silent", "--show-error", "--location", "--max-time", "15", "--proto", "=https", "--header", "Accept: application/vnd.github+json", "--user-agent", concat!("NeoLink/", env!("CARGO_PKG_VERSION")), LATEST])
        .stdin(std::process::Stdio::null())
        .output();
    let output = match output {
        Ok(output) => output,
        Err(error) => return Found::Failed(format!("curl could not be started: {error}")),
    };
    if !output.status.success() {
        let reason = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Found::Failed(if reason.is_empty() { "GitHub did not answer.".into() } else { reason });
    }
    answer(&output.stdout, env!("CARGO_PKG_VERSION"))
}

/// Reads GitHub's answer about the latest release against the running `current` version.
fn answer(json: &[u8], current: &str) -> Found {
    let Ok(release) = serde_json::from_slice::<serde_json::Value>(json) else { return Found::Failed("GitHub's answer could not be read.".into()) };
    let Some(tag) = release["tag_name"].as_str() else { return Found::Failed("GitHub named no release.".into()) };
    let page = release["html_url"].as_str().filter(|url| url.starts_with("https://github.com/")).unwrap_or(RELEASES).to_string();
    match (version(tag), version(current)) {
        (Some(latest), Some(running)) if latest > running => Found::Newer(tag.trim_start_matches('v').to_string(), page),
        (Some(_), Some(_)) => Found::UpToDate,
        _ => Found::Failed(format!("Unexpected release name {tag}.")),
    }
}

/// "v2.1.0" or "2.1" as comparable numbers.
fn version(text: &str) -> Option<(u64, u64, u64)> {
    let mut parts = text.trim().trim_start_matches('v').split('.').map(|part| part.parse::<u64>().ok());
    let major = parts.next()??;
    let minor = parts.next().unwrap_or(Some(0))?;
    let patch = parts.next().unwrap_or(Some(0))?;
    parts.next().is_none().then_some((major, minor, patch))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions_compare_as_numbers() {
        assert_eq!(version("v2.1.0"), Some((2, 1, 0)));
        assert_eq!(version("2.10"), Some((2, 10, 0)));
        assert_eq!(version("2.1.0-beta"), None);
        let release = |tag: &str| format!(r#"{{"tag_name": "{tag}", "html_url": "https://github.com/abhayasho/NeoLink/releases/tag/{tag}"}}"#);
        assert_eq!(answer(release("v2.10.0").as_bytes(), "2.9.3"), Found::Newer("2.10.0".into(), "https://github.com/abhayasho/NeoLink/releases/tag/v2.10.0".into()));
        assert_eq!(answer(release("v2.1.0").as_bytes(), "2.1.0"), Found::UpToDate);
        assert_eq!(answer(release("v2.0.4").as_bytes(), "2.1.0"), Found::UpToDate);
        assert!(matches!(answer(b"not json", "2.1.0"), Found::Failed(_)));
        // A release page elsewhere is never opened.
        let elsewhere = br#"{"tag_name": "v9.0.0", "html_url": "https://example.com/x"}"#;
        assert_eq!(answer(elsewhere, "2.1.0"), Found::Newer("9.0.0".into(), RELEASES.into()));
    }
}
