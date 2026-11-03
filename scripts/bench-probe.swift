// Benchmark validity probe: prints one JSON line every 250 ms with the screen-lock state,
// the frontmost application's process ID, the NeoLink window's on-screen bounds, and the
// seconds since the last real keyboard/mouse/trackpad input (synthetic events NeoLink
// delivers to itself do not count). Used by scripts/bench-run.py; needs no Accessibility
// or Screen Recording permission. `bench-probe --idle` prints the idle seconds once.
import AppKit
import CoreGraphics
import IOKit

func inputIdleSeconds() -> Double {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"), &iterator) == KERN_SUCCESS else { return -1 }
    defer { IOObjectRelease(iterator) }
    let entry = IOIteratorNext(iterator)
    guard entry != 0 else { return -1 }
    defer { IOObjectRelease(entry) }
    var properties: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let values = properties?.takeRetainedValue() as? [String: Any],
          let idle = values["HIDIdleTime"] as? NSNumber else { return -1 }
    return idle.doubleValue / 1_000_000_000
}

if CommandLine.arguments.dropFirst().first == "--idle" {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
    let locked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
    print("{\"idle\":\(inputIdleSeconds()),\"locked\":\(locked)}")
    exit(0)
}

let target = CommandLine.arguments.count > 1 ? Int32(CommandLine.arguments[1]) ?? 0 : 0
setvbuf(stdout, nil, _IOLBF, 0)
while true {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
    let locked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    var onScreen = false, bounds = ""
    if target != 0, let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
        for window in list where (window[kCGWindowOwnerPID as String] as? Int32) == target && (window[kCGWindowLayer as String] as? Int) == 0 {
            if let b = window[kCGWindowBounds as String] as? [String: Double], (b["Width"] ?? 0) > 400 {
                onScreen = true
                bounds = "\(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0))"
            }
        }
    }
    print("{\"t\":\(Date().timeIntervalSince1970),\"locked\":\(locked),\"front\":\(front),\"onScreen\":\(onScreen),\"bounds\":\"\(bounds)\",\"idle\":\(inputIdleSeconds())}")
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25)) // Updates frontmostApplication.
}
