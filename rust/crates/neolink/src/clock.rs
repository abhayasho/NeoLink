//! One monotonic clock for input timestamps, frame times and display times.
//!
//! On macOS this is `CACurrentMediaTime()`: the timebase of `NSEvent.timestamp` and of a drawable's
//! `presentedTime`, so the three can be subtracted directly. Elsewhere it is seconds since the process
//! started.

#[cfg(target_os = "macos")]
pub fn now() -> f64 {
    #[link(name = "QuartzCore", kind = "framework")]
    unsafe extern "C" {
        fn CACurrentMediaTime() -> f64;
    }
    unsafe { CACurrentMediaTime() }
}

#[cfg(not(target_os = "macos"))]
pub fn now() -> f64 {
    use std::sync::OnceLock;
    use std::time::Instant;
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_secs_f64()
}

/// Sleeps until `deadline` on this clock; returns at once if it has passed.
pub fn sleep_until(deadline: f64) {
    let remaining = deadline - now();
    if remaining > 0.0 {
        std::thread::sleep(std::time::Duration::from_secs_f64(remaining));
    }
}
