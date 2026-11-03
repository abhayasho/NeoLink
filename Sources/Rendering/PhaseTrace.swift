import Darwin
import Foundation
import os
import QuartzCore

/// Named moments of launch and of opening a file, for measuring where time goes. The first
/// occurrence of each name is kept (in `CACurrentMediaTime` seconds) and also emitted as a
/// point-of-interest signpost, so Instruments shows the same phases. Recording a moment is a
/// dictionary lookup; nothing is kept after the first occurrence.
@MainActor
enum PhaseTrace {
    private static let log = OSLog(subsystem: "com.neolink.app", category: .pointsOfInterest)
    private(set) static var moments: [String: Double] = [:]

    static func mark(_ name: String, at time: Double? = nil) {
        guard moments[name] == nil else { return }
        moments[name] = time ?? CACurrentMediaTime()
        os_signpost(.event, log: log, name: "Phase", "%{public}s", name)
    }

    /// Runs `work` and records `name.begin` and `name.end` around it the first time.
    static func measure<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
        let first = moments[name + ".begin"] == nil
        if first { mark(name + ".begin") }
        defer { if first { mark(name + ".end") } }
        return try work()
    }

    /// When the kernel started this process, on the `CACurrentMediaTime` clock (includes the
    /// time before `main`: exec, dyld and static initializers).
    nonisolated static var processStart: Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return CACurrentMediaTime() }
        let start = info.kp_proc.p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return CACurrentMediaTime() - (Date().timeIntervalSince1970 - started)
    }
}
