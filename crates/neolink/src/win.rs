//! Windows-only system services: the display's refresh clock, timer resolution, thread priority, wheel
//! settings, which GPU drives a display, the PATH as the system has it now, and the terminal shell's
//! working directory.
//!
//! Why the refresh clock matters: on macOS every presented frame reports when it reached the display,
//! and the pacer follows those times. A wgpu surface on Windows reports nothing, and the monitor's rate
//! as Windows states it is a whole number of hertz (143 for a 143.86 Hz panel). A frame grid built from
//! that drifts across the real refreshes, and every few hundred milliseconds one refresh gets two
//! frames and the next none: a regular stutter. This clock instead waits for the display's vertical
//! blank on a thread of its own (only while frames are being drawn), and fits the refresh grid to it.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;
use windows_sys::Wdk::Graphics::Direct3D::{
    D3DKMTCloseAdapter, D3DKMTOpenAdapterFromGdiDisplayName, D3DKMTWaitForVerticalBlankEvent, D3DKMT_CLOSEADAPTER, D3DKMT_OPENADAPTERFROMGDIDISPLAYNAME,
    D3DKMT_WAITFORVERTICALBLANKEVENT,
};

/// Seconds on the performance counter: the clock of input, frames and vertical blanks alike.
pub fn qpc_seconds() -> f64 {
    use windows_sys::Win32::System::Performance::{QueryPerformanceCounter, QueryPerformanceFrequency};
    static FREQUENCY: OnceLock<f64> = OnceLock::new();
    let frequency = *FREQUENCY.get_or_init(|| {
        let mut frequency = 0i64;
        unsafe { QueryPerformanceFrequency(&mut frequency) };
        frequency.max(1) as f64
    });
    let mut counter = 0i64;
    unsafe { QueryPerformanceCounter(&mut counter) };
    counter as f64 / frequency
}

/// CPU seconds used so far by the calling thread.
pub fn thread_cpu_seconds() -> f64 {
    use windows_sys::Win32::Foundation::FILETIME;
    use windows_sys::Win32::System::Threading::{GetCurrentThread, GetThreadTimes};
    let zero = FILETIME { dwLowDateTime: 0, dwHighDateTime: 0 };
    let (mut created, mut exited, mut kernel, mut user) = (zero, zero, zero, zero);
    if unsafe { GetThreadTimes(GetCurrentThread(), &mut created, &mut exited, &mut kernel, &mut user) } == 0 {
        return 0.0;
    }
    let ticks = |time: FILETIME| ((time.dwHighDateTime as u64) << 32 | time.dwLowDateTime as u64) as f64 / 1e7;
    ticks(kernel) + ticks(user)
}

/// The render thread runs above normal priority, as macOS's user-interactive class does: a frame that
/// is ready but not scheduled misses its refresh.
pub fn raise_thread_priority() {
    use windows_sys::Win32::System::Threading::{GetCurrentThread, SetThreadPriority, THREAD_PRIORITY_HIGHEST};
    unsafe { SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST) };
}

/// Windows' default timer tick is 15.6 ms: a thread asked to wake in 3 ms wakes up to 15 ms later,
/// skipping whole refreshes. While frames are drawn the tick is 1 ms; idle, the system's default
/// (a finer tick costs power for the whole machine).
pub fn fine_timer(on: bool) {
    use windows_sys::Win32::Media::{timeBeginPeriod, timeEndPeriod};
    static ON: AtomicBool = AtomicBool::new(false);
    if ON.swap(on, Ordering::AcqRel) != on {
        unsafe {
            if on {
                timeBeginPeriod(1);
            } else {
                timeEndPeriod(1);
            }
        }
    }
}

/// Lines per wheel notch and characters per sideways notch, as set in Windows' mouse settings.
/// `None` for lines means "one screen per notch".
pub fn wheel_settings() -> (Option<f64>, f64) {
    use windows_sys::Win32::UI::WindowsAndMessaging::{SystemParametersInfoW, SPI_GETWHEELSCROLLCHARS, SPI_GETWHEELSCROLLLINES};
    let (mut lines, mut chars) = (3u32, 3u32);
    unsafe {
        SystemParametersInfoW(SPI_GETWHEELSCROLLLINES, 0, &mut lines as *mut u32 as *mut _, 0);
        SystemParametersInfoW(SPI_GETWHEELSCROLLCHARS, 0, &mut chars as *mut u32 as *mut _, 0);
    }
    // WHEEL_PAGESCROLL
    let lines = if lines == u32::MAX { None } else { Some(lines.min(100) as f64) };
    (lines, chars.min(100) as f64)
}

/// The name of the graphics adapter that drives the display `device` (`\\.\DISPLAY1`), as Windows
/// lists it ("NVIDIA GeForce RTX 4070 SUPER"): the adapter that should draw a window shown there.
/// Drawing on another one (the integrated GPU of a desktop whose monitors are on the graphics card)
/// copies every frame across adapters, which costs a refresh and drops frames.
pub fn adapter_for_display(device: &str) -> Option<String> {
    use windows_sys::Win32::Graphics::Gdi::{EnumDisplayDevicesW, DISPLAY_DEVICEW};
    let wide = |text: &[u16]| String::from_utf16_lossy(&text[..text.iter().position(|c| *c == 0).unwrap_or(text.len())]);
    for index in 0.. {
        let mut entry: DISPLAY_DEVICEW = unsafe { std::mem::zeroed() };
        entry.cb = std::mem::size_of::<DISPLAY_DEVICEW>() as u32;
        if unsafe { EnumDisplayDevicesW(std::ptr::null(), index, &mut entry, 0) } == 0 {
            break;
        }
        if wide(&entry.DeviceName).eq_ignore_ascii_case(device) {
            return Some(wide(&entry.DeviceString)).filter(|name| !name.is_empty());
        }
    }
    None
}

/// Programs installed after Windows signed in (Neovim, Git, ripgrep through the installer) are on the
/// PATH stored in the registry but not on the one this process inherited from Explorer. Adds the
/// stored entries the inherited PATH lacks. Called first thing in `main`, before any thread starts.
pub fn refresh_path() {
    use windows_sys::Win32::System::Registry::{RegGetValueW, HKEY, HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, RRF_RT_REG_SZ};
    let wide = |text: &str| text.encode_utf16().chain(Some(0)).collect::<Vec<u16>>();
    let read = |root: HKEY, key: &str| -> Option<String> {
        let (key, value) = (wide(key), wide("Path"));
        let mut bytes = 0u32;
        // REG_EXPAND_SZ values are expanded by RegGetValueW when only RRF_RT_REG_SZ is asked for.
        if unsafe { RegGetValueW(root, key.as_ptr(), value.as_ptr(), RRF_RT_REG_SZ, std::ptr::null_mut(), std::ptr::null_mut(), &mut bytes) } != 0 {
            return None;
        }
        let mut buffer = vec![0u16; bytes as usize / 2 + 1];
        if unsafe { RegGetValueW(root, key.as_ptr(), value.as_ptr(), RRF_RT_REG_SZ, std::ptr::null_mut(), buffer.as_mut_ptr() as *mut _, &mut bytes) } != 0 {
            return None;
        }
        Some(String::from_utf16_lossy(&buffer[..buffer.iter().position(|c| *c == 0).unwrap_or(buffer.len())]))
    };
    let stored = [
        read(HKEY_LOCAL_MACHINE, r"SYSTEM\CurrentControlSet\Control\Session Manager\Environment"),
        read(HKEY_CURRENT_USER, "Environment"),
    ];
    let current = std::env::var("PATH").unwrap_or_default();
    let normal = |entry: &str| entry.trim().trim_end_matches(['\\', '/']).to_lowercase();
    let mut known: Vec<String> = current.split(';').map(normal).collect();
    let mut path = current.clone();
    for entry in stored.iter().flatten().flat_map(|value| value.split(';')) {
        let entry = entry.trim();
        if entry.is_empty() || known.contains(&normal(entry)) {
            continue;
        }
        known.push(normal(entry));
        if !path.is_empty() && !path.ends_with(';') {
            path.push(';');
        }
        path.push_str(entry);
    }
    if path != current {
        // Before any other thread exists (see the caller).
        unsafe { std::env::set_var("PATH", path) };
    }
}

/// The vertical blank of the display showing the window, measured on a thread that waits for it.
pub struct VBlank {
    /// GDI name of the display (`\\.\DISPLAY1`).
    display: Mutex<String>,
    /// Display time until which a frame is expected to want the clock (`f64` bits). Past it, the
    /// thread sleeps without a deadline.
    wanted_until: AtomicU64,
    /// The fitted grid: a refresh time and the refresh interval (`f64` bits, 0 while unknown).
    vblank: AtomicU64,
    period: AtomicU64,
    thread: OnceLock<std::thread::Thread>,
}

/// The clock, started on first use.
pub fn vblank() -> &'static VBlank {
    static CLOCK: OnceLock<VBlank> = OnceLock::new();
    CLOCK.get_or_init(|| VBlank {
        display: Mutex::new(String::new()),
        wanted_until: AtomicU64::new(0f64.to_bits()),
        vblank: AtomicU64::new(0f64.to_bits()),
        period: AtomicU64::new(0f64.to_bits()),
        thread: OnceLock::new(),
    })
}

/// How long the clock keeps measuring after the last frame asked for it.
const KEEP_MEASURING: f64 = 2.0;
/// Refreshes the grid is fitted over.
const FIT_SAMPLES: usize = 120;

impl VBlank {
    /// The window is on display `device` now (at launch, and after it moved).
    pub fn set_display(&'static self, device: String) {
        let mut display = self.display.lock().unwrap();
        if *display != device {
            *display = device;
            self.vblank.store(0f64.to_bits(), Ordering::Release);
            self.period.store(0f64.to_bits(), Ordering::Release);
        }
        drop(display);
        self.start();
    }

    fn start(&'static self) {
        if self.thread.get().is_some() {
            return;
        }
        if std::env::var("NEOLINK_VBLANK").as_deref() == Ok("0") {
            return;
        }
        let handle = std::thread::Builder::new().name("vblank".into()).spawn(move || self.run());
        if let Ok(handle) = handle {
            let _ = self.thread.set(handle.thread().clone());
        }
    }

    /// The render thread is drawing: keep measuring. Returns the latest grid `(refresh time, interval)`
    /// once enough refreshes were seen to know the interval precisely.
    pub fn sample(&self, now: f64) -> Option<(f64, f64)> {
        let previous = f64::from_bits(self.wanted_until.swap((now + KEEP_MEASURING).to_bits(), Ordering::AcqRel));
        if previous < now {
            if let Some(thread) = self.thread.get() {
                thread.unpark();
            }
        }
        let (vblank, period) = (f64::from_bits(self.vblank.load(Ordering::Acquire)), f64::from_bits(self.period.load(Ordering::Acquire)));
        // A grid not refreshed for a while (the thread was asleep) may have drifted.
        (vblank > 0.0 && period > 0.0 && now - vblank < 0.25).then_some((vblank, period))
    }

    fn run(&'static self) {
        raise_thread_priority();
        let mut adapter: Option<(String, u32, u32)> = None;
        let mut samples: VecDeque<f64> = VecDeque::with_capacity(FIT_SAMPLES + 1);
        let close = |handle: u32| unsafe {
            D3DKMTCloseAdapter(&D3DKMT_CLOSEADAPTER { hAdapter: handle });
        };
        loop {
            let now = qpc_seconds();
            if now > f64::from_bits(self.wanted_until.load(Ordering::Acquire)) {
                // Idle: nothing is drawn, nothing is measured. The samples are stale afterwards.
                samples.clear();
                self.vblank.store(0f64.to_bits(), Ordering::Release);
                std::thread::park();
                continue;
            }
            let display = self.display.lock().unwrap().clone();
            if adapter.as_ref().is_none_or(|open| open.0 != display) {
                if let Some(open) = adapter.take() {
                    close(open.1);
                }
                samples.clear();
                let mut request = D3DKMT_OPENADAPTERFROMGDIDISPLAYNAME::default();
                for (slot, unit) in request.DeviceName.iter_mut().zip(display.encode_utf16().take(31)) {
                    *slot = unit;
                }
                if display.is_empty() || unsafe { D3DKMTOpenAdapterFromGdiDisplayName(&mut request) } != 0 {
                    // Not available (a remote session, an unusual driver): the pacer keeps its own grid.
                    std::thread::park_timeout(Duration::from_secs(1));
                    continue;
                }
                adapter = Some((display, request.hAdapter, request.VidPnSourceId));
            }
            let (_, handle, source) = adapter.clone().unwrap();
            let status = unsafe { D3DKMTWaitForVerticalBlankEvent(&D3DKMT_WAITFORVERTICALBLANKEVENT { hAdapter: handle, hDevice: 0, VidPnSourceId: source }) };
            let at = qpc_seconds();
            if status != 0 {
                // The display was turned off or reconfigured: open it again.
                if let Some(open) = adapter.take() {
                    close(open.1);
                }
                std::thread::park_timeout(Duration::from_millis(250));
                continue;
            }
            samples.push_back(at);
            if samples.len() > FIT_SAMPLES {
                samples.pop_front();
            }
            if let Some((vblank, period)) = fit_grid(&samples) {
                if samples.len() == FIT_SAMPLES / 2 && std::env::var_os("NEOLINK_DEBUG_FRAMES").is_some() {
                    eprintln!("VBLANK {} {:.4} Hz", adapter.as_ref().map_or("", |open| open.0.as_str()), 1.0 / period);
                }
                self.period.store(period.to_bits(), Ordering::Release);
                self.vblank.store(vblank.to_bits(), Ordering::Release);
            }
        }
    }
}

/// Fits a refresh grid to the times a thread woke for vertical blanks. Each wake comes a little after
/// its refresh (scheduling), and one may be missed entirely; so the interval is a least-squares fit over
/// refresh numbers, and the grid is placed on the earliest wakes (the ones scheduled with least delay).
/// Returns `(time of the latest refresh, interval)`.
pub fn fit_grid(samples: &VecDeque<f64>) -> Option<(f64, f64)> {
    if samples.len() < 8 {
        return None;
    }
    let first = samples[0];
    // A rough interval from the shortest gaps (missed refreshes make some gaps double).
    let mut gaps: Vec<f64> = samples.iter().zip(samples.iter().skip(1)).map(|(a, b)| b - a).filter(|gap| *gap > 0.001).collect();
    if gaps.len() < 4 {
        return None;
    }
    gaps.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let rough = gaps[gaps.len() / 4..gaps.len() * 3 / 4 + 1].iter().sum::<f64>() / (gaps.len() * 3 / 4 + 1 - gaps.len() / 4) as f64;
    // Numbered gap by gap: a rough interval a fraction of a percent off would misnumber refreshes
    // counted from the first sample a hundred refreshes back, but never a single gap.
    let mut numbered: Vec<(f64, f64)> = Vec::with_capacity(samples.len());
    let mut k = 0.0;
    let mut previous = first;
    for time in samples {
        k += ((time - previous) / rough).round();
        previous = *time;
        numbered.push((k, *time));
    }
    let count = numbered.len() as f64;
    let (mean_k, mean_t) = (numbered.iter().map(|s| s.0).sum::<f64>() / count, numbered.iter().map(|s| s.1).sum::<f64>() / count);
    let (mut covariance, mut variance) = (0.0, 0.0);
    for (k, time) in &numbered {
        covariance += (k - mean_k) * (time - mean_t);
        variance += (k - mean_k) * (k - mean_k);
    }
    if variance <= 0.0 {
        return None;
    }
    let period = covariance / variance;
    if !(0.002..0.1).contains(&period) {
        return None;
    }
    let intercept = mean_t - period * mean_k;
    // The lower envelope: wakes are never early, only late.
    let earliest = numbered.iter().map(|(k, time)| time - (intercept + period * k)).fold(f64::INFINITY, f64::min);
    let last_k = numbered.last().unwrap().0;
    Some((intercept + earliest + period * last_k, period))
}

/// The working directory of process `pid`: the one `SetCurrentDirectory` changes, read from the
/// process's parameters (what macOS's `proc_pidinfo` answers). 64-bit processes only, as this one is.
pub fn process_directory(pid: u32) -> Option<std::path::PathBuf> {
    use windows_sys::Wdk::System::Threading::{NtQueryInformationProcess, ProcessBasicInformation};
    use windows_sys::Win32::Foundation::CloseHandle;
    use windows_sys::Win32::System::Diagnostics::Debug::ReadProcessMemory;
    use windows_sys::Win32::System::Threading::{IsWow64Process, OpenProcess, PROCESS_QUERY_INFORMATION, PROCESS_VM_READ};
    /// `PROCESS_BASIC_INFORMATION`.
    #[repr(C)]
    struct Basic {
        exit_status: i32,
        peb: usize,
        affinity: usize,
        priority: i32,
        id: usize,
        parent: usize,
    }
    let process = unsafe { OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, 0, pid) };
    if process.is_null() {
        return None;
    }
    let read = |address: usize, buffer: &mut [u8]| {
        let mut done = 0usize;
        (unsafe { ReadProcessMemory(process, address as *const _, buffer.as_mut_ptr().cast(), buffer.len(), &mut done) }) != 0 && done == buffer.len()
    };
    let directory = (|| {
        let mut wow64 = 0;
        if unsafe { IsWow64Process(process, &mut wow64) } == 0 || wow64 != 0 {
            return None;
        }
        let mut basic = Basic { exit_status: 0, peb: 0, affinity: 0, priority: 0, id: 0, parent: 0 };
        let mut length = 0u32;
        let status = unsafe { NtQueryInformationProcess(process, ProcessBasicInformation, (&mut basic as *mut Basic).cast(), std::mem::size_of::<Basic>() as u32, &mut length) };
        if status < 0 || basic.peb == 0 {
            return None;
        }
        // 64-bit layouts: PEB.ProcessParameters at 0x20, and in RTL_USER_PROCESS_PARAMETERS the
        // current directory's path (a UNICODE_STRING: length in bytes, then the buffer at +8) at 0x38.
        let mut word = [0u8; 8];
        if !read(basic.peb + 0x20, &mut word) {
            return None;
        }
        let parameters = usize::from_ne_bytes(word);
        let mut string = [0u8; 16];
        if parameters == 0 || !read(parameters + 0x38, &mut string) {
            return None;
        }
        let length = u16::from_ne_bytes([string[0], string[1]]) as usize;
        let buffer = usize::from_ne_bytes(string[8..16].try_into().ok()?);
        if length == 0 || buffer == 0 {
            return None;
        }
        let mut bytes = vec![0u8; length];
        if !read(buffer, &mut bytes) {
            return None;
        }
        let units: Vec<u16> = bytes.chunks_exact(2).map(|pair| u16::from_ne_bytes([pair[0], pair[1]])).collect();
        let mut path = String::from_utf16(&units).ok()?;
        // `C:\work\` is `C:\work`; a drive's root keeps its backslash.
        if path.len() > 3 && path.ends_with('\\') {
            path.pop();
        }
        Some(std::path::PathBuf::from(path))
    })();
    unsafe { CloseHandle(process) };
    directory
}

/// The shell the user is typing into: `shell`, or the newest shell started inside it (and inside that,
/// and so on): `cmd` run from PowerShell, Git's `bash`. What macOS asks the terminal for as its
/// foreground process. Other programs (an editor, a build) are passed over: their directory is not
/// where the user is.
pub fn foreground_shell(shell: u32) -> u32 {
    use windows_sys::Win32::Foundation::{CloseHandle, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS};
    const SHELLS: [&str; 8] = ["cmd.exe", "powershell.exe", "pwsh.exe", "bash.exe", "sh.exe", "zsh.exe", "fish.exe", "nu.exe"];
    let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) };
    if snapshot == INVALID_HANDLE_VALUE {
        return shell;
    }
    let mut processes = Vec::new();
    let mut entry: PROCESSENTRY32W = unsafe { std::mem::zeroed() };
    entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
    let mut more = unsafe { Process32FirstW(snapshot, &mut entry) } != 0;
    while more {
        let end = entry.szExeFile.iter().position(|unit| *unit == 0).unwrap_or(entry.szExeFile.len());
        let name = String::from_utf16_lossy(&entry.szExeFile[..end]).to_ascii_lowercase();
        processes.push((entry.th32ProcessID, entry.th32ParentProcessID, SHELLS.contains(&name.as_str())));
        more = unsafe { Process32NextW(snapshot, &mut entry) } != 0;
    }
    unsafe { CloseHandle(snapshot) };
    let mut current = shell;
    let mut started = process_started(shell);
    for _ in 0..8 {
        // Only a child started after its parent: process ids are reused, and an old process may name
        // as its parent an id that is now the shell's.
        let newest = processes
            .iter()
            .filter(|(id, parent, is_shell)| *parent == current && *is_shell && *id != current)
            .filter_map(|(id, _, _)| process_started(*id).filter(|time| started.is_none_or(|started| *time >= started)).map(|time| (*id, time)))
            .max_by_key(|(_, time)| *time);
        let Some((id, time)) = newest else { break };
        current = id;
        started = Some(time);
    }
    current
}

/// When process `pid` started (100 ns ticks), if it is still running.
fn process_started(pid: u32) -> Option<u64> {
    use windows_sys::Win32::Foundation::{CloseHandle, FILETIME};
    use windows_sys::Win32::System::Threading::{GetProcessTimes, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION};
    let process = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
    if process.is_null() {
        return None;
    }
    let zero = FILETIME { dwLowDateTime: 0, dwHighDateTime: 0 };
    let (mut created, mut exited, mut kernel, mut user) = (zero, zero, zero, zero);
    let known = unsafe { GetProcessTimes(process, &mut created, &mut exited, &mut kernel, &mut user) } != 0;
    unsafe { CloseHandle(process) };
    known.then(|| (created.dwHighDateTime as u64) << 32 | created.dwLowDateTime as u64)
}

/// The prompt hook: PowerShell's `cd` moves only its own location, which no other program can see.
/// At every prompt this makes that location the process's working directory too, so the explorer
/// can follow the terminal. It wraps whatever prompt the user's profile set.
const PROMPT_HOOK: &str = "$global:__NeoLinkPrompt = $function:prompt
function global:prompt {
    $text = & $global:__NeoLinkPrompt
    if ($PWD.Provider.Name -eq 'FileSystem') { [Environment]::CurrentDirectory = $PWD.ProviderPath }
    $text
}
";

/// The user's shell for a terminal tab: Windows PowerShell with its profile, and the prompt hook.
pub fn shell() -> (String, Vec<String>) {
    let units: Vec<u8> = PROMPT_HOOK.encode_utf16().flat_map(u16::to_le_bytes).collect();
    ("powershell.exe".into(), vec!["-NoExit".into(), "-EncodedCommand".into(), base64(&units)])
}

fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut text = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let value = (chunk[0] as u32) << 16 | (*chunk.get(1).unwrap_or(&0) as u32) << 8 | *chunk.get(2).unwrap_or(&0) as u32;
        for index in 0..4 {
            text.push(if index <= chunk.len() { ALPHABET[(value >> (18 - 6 * index) & 63) as usize] as char } else { '=' });
        }
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_grid_is_fitted_through_late_and_missed_wakes() {
        let period = 1.0 / 143.86;
        let mut seed: u64 = 11;
        let mut samples = VecDeque::new();
        for k in 0..120u32 {
            if k % 17 == 5 {
                continue; // a refresh the thread slept through
            }
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            let late = 0.00002 + (seed >> 40) as f64 / (1u64 << 24) as f64 * 0.0004;
            samples.push_back(3.0 + k as f64 * period + late);
        }
        let (vblank, fitted) = fit_grid(&samples).unwrap();
        // The grid is refitted at every refresh and used for at most 0.25 s: 1.5 µs per refresh is
        // under 0.06 ms of drift in that time.
        assert!((fitted - period).abs() < 1.5e-6, "interval {fitted} vs {period}");
        let phase = ((vblank - 3.0) / period).fract();
        let error = phase.min(1.0 - phase) * period;
        assert!(error < 0.0001, "grid off by {:.3} ms", error * 1000.0);
    }

    #[test]
    fn base64_matches_the_standard_encoding() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(base64(b"foobar"), "Zm9vYmFy");
    }

    fn plain(path: &std::path::Path) -> String {
        path.to_string_lossy().trim_start_matches(r"\\?\").to_lowercase()
    }

    #[test]
    fn another_process_reports_its_working_directory() {
        let directory = std::env::temp_dir().canonicalize().unwrap();
        let mut child = std::process::Command::new("ping").args(["-n", "30", "127.0.0.1"]).current_dir(&directory).stdout(std::process::Stdio::null()).spawn().unwrap();
        std::thread::sleep(Duration::from_millis(300));
        let reported = process_directory(child.id());
        let _ = child.kill();
        assert_eq!(reported.as_deref().map(plain), Some(plain(&directory)));
    }

    #[test]
    fn the_prompt_hook_moves_the_working_directory_with_cd() {
        let target = std::env::temp_dir().canonicalize().unwrap();
        let script = format!("{PROMPT_HOOK}\nSet-Location -LiteralPath '{}'\n$null = prompt\n[Environment]::CurrentDirectory", plain(&target));
        let output = std::process::Command::new("powershell.exe").args(["-NoProfile", "-NonInteractive", "-Command", &script]).current_dir(std::env::var("SystemRoot").unwrap()).output().unwrap();
        assert_eq!(String::from_utf8_lossy(&output.stdout).trim().to_lowercase(), plain(&target));
    }
}
