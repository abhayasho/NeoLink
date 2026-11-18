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

/// CPU seconds used so far by the calling thread (0 where the system cannot tell).
pub fn thread_cpu_seconds() -> f64 {
    #[cfg(unix)]
    {
        let mut time = libc::timespec { tv_sec: 0, tv_nsec: 0 };
        if unsafe { libc::clock_gettime(libc::CLOCK_THREAD_CPUTIME_ID, &mut time) } == 0 {
            return time.tv_sec as f64 + time.tv_nsec as f64 / 1e9;
        }
    }
    0.0
}
