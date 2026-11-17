//! What the app remembers between runs (the Swift app keeps these in `UserDefaults` and the window's
//! autosaved frame): the window, which panels are shown and how wide, the text size, explorer options,
//! the project and the recent projects, the custom agent. One small JSON file; a missing or damaged file
//! means defaults.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    /// Window position and inner size in points; `None` until the window has been placed once.
    pub window: Option<(f64, f64, f64, f64)>,
    pub font_points: f32,
    pub explorer_visible: bool,
    pub connections_visible: bool,
    pub explorer_points: f32,
    pub compact_folders: bool,
    pub folder_list: bool,
    pub folder_sort: usize,
    pub show_hidden: bool,
    pub hide_ignored: bool,
    pub reveal_active: bool,
    pub agent_visible: bool,
    pub agent_points: f32,
    pub dock_right: bool,
    pub dock_height: f32,
    pub dock_width: f32,
    pub custom_agent_name: String,
    pub custom_agent_executable: String,
    pub project: Option<PathBuf>,
    pub recent_projects: Vec<PathBuf>,
    /// View > Pixel-Smooth Sideways Scrolling (preview; off until checked with a real trackpad).
    pub pixel_sideways: bool,
}

impl Default for Settings {
    fn default() -> Settings {
        Settings {
            window: None,
            font_points: 13.0,
            explorer_visible: true,
            connections_visible: false,
            explorer_points: 250.0,
            compact_folders: true,
            folder_list: false,
            folder_sort: 0,
            show_hidden: false,
            hide_ignored: false,
            reveal_active: true,
            agent_visible: false,
            agent_points: 300.0,
            dock_right: false,
            dock_height: 220.0,
            dock_width: 420.0,
            custom_agent_name: "My agent".into(),
            custom_agent_executable: String::new(),
            project: None,
            recent_projects: Vec::new(),
            pixel_sideways: false,
        }
    }
}

/// Where the file is. `None` when settings are off (`NEOLINK_SETTINGS=0`, benchmarks, captures), so
/// measurements and tests always start from the same state.
pub fn path() -> Option<PathBuf> {
    // A named file is used even in a benchmark or capture (that is how the settings are tested).
    if let Some(file) = std::env::var_os("NEOLINK_SETTINGS_FILE") {
        return Some(PathBuf::from(file));
    }
    if std::env::var("NEOLINK_SETTINGS").as_deref() == Ok("0") || std::env::var_os("NEOLINK_BENCHMARK").is_some() || std::env::var_os("NEOLINK_CAPTURE").is_some() {
        return None;
    }
    let home = std::env::var_os("HOME").map(PathBuf::from);
    if cfg!(target_os = "macos") {
        Some(home?.join("Library/Application Support/NeoLink/settings.json"))
    } else if cfg!(windows) {
        Some(PathBuf::from(std::env::var_os("APPDATA")?).join("NeoLink").join("settings.json"))
    } else {
        Some(std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from).or_else(|| home.map(|home| home.join(".config")))?.join("neolink/settings.json"))
    }
}

pub fn load() -> Settings {
    path().and_then(|path| std::fs::read(path).ok()).and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default()
}

/// Writes the file through a temporary one, so a crash never leaves half of it.
pub fn save(settings: &Settings) {
    let Some(path) = path() else { return };
    let Ok(data) = serde_json::to_vec_pretty(settings) else { return };
    if let Some(directory) = path.parent() {
        let _ = std::fs::create_dir_all(directory);
    }
    let temporary = path.with_extension("json.tmp");
    if std::fs::write(&temporary, data).is_ok() {
        let _ = std::fs::rename(&temporary, &path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_and_missing_fields_fall_back_to_defaults() {
        let settings: Settings = serde_json::from_str(r#"{"font_points": 16.0, "from_a_newer_version": true}"#).unwrap();
        assert_eq!(settings.font_points, 16.0);
        assert_eq!(settings.explorer_points, 250.0);
        assert!(settings.explorer_visible && settings.reveal_active && !settings.agent_visible);
        let text = serde_json::to_string(&settings).unwrap();
        assert_eq!(serde_json::from_str::<Settings>(&text).unwrap(), settings);
    }
}
