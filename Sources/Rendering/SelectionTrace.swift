import Foundation
import QuartzCore

/// Opt-in, bounded, per-selection telemetry. Host events use mach monotonic seconds
/// (CACurrentMediaTime); editor hrtime events carry an explicit round-trip mapping.
/// No paths, source text or input characters are recorded.
enum SelectionTrace {
    static let enabled = ProcessInfo.processInfo.environment["NEOLINK_SELECTION_TRACE"] != nil
    private static let storage = Storage()
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var events: [[String: Any]] = []
        var first: Set<String> = []
        var current: UInt64 = 0
    }
    static func reset() {
        storage.lock.lock(); defer { storage.lock.unlock() }
        storage.events.removeAll(keepingCapacity: true); storage.first.removeAll(keepingCapacity: true)
    }
    static func mark(_ token: UInt64, _ phase: String, at time: Double = CACurrentMediaTime(), once: Bool = true,
                     fields: [String: Any] = [:]) {
        guard enabled, token > 0 else { return }
        storage.lock.lock(); defer { storage.lock.unlock() }
        guard storage.events.count < 8192 else { return }
        if once, !storage.first.insert("\(token):\(phase)").inserted { return }
        if phase == "selection.begin" { storage.current = token }
        var event = fields
        event["selection"] = token; event["phase"] = phase; event["time"] = time
        storage.events.append(event)
    }
    static func remote(_ token: UInt64, _ times: [String: Double], sent: Double, received: Double) {
        guard enabled, let begin = times["dispatch"], let end = times["ack"] else { return }
        let offset = (sent + received - begin - end) / 2
        let uncertainty = max(0, (received - sent - (end - begin)) / 2)
        for (phase, remote) in times {
            mark(token, "nvim." + phase, at: remote + offset,
                 fields: ["remoteSeconds": remote, "clockOffsetSeconds": offset, "clockUncertaintySeconds": uncertainty])
        }
    }
    static var current: UInt64 {
        guard enabled else { return 0 }
        storage.lock.lock(); defer { storage.lock.unlock() }; return storage.current
    }
    static func time(_ token: UInt64, _ phase: String) -> Double? {
        storage.lock.lock(); defer { storage.lock.unlock() }
        return storage.events.first { ($0["selection"] as? UInt64) == token && ($0["phase"] as? String) == phase }?["time"] as? Double
    }
    static func writeIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["NEOLINK_SELECTION_TRACE"], path != "1" else { return }
        let payload: [String: Any] = ["clock": "CACurrentMediaTime monotonic seconds; nvim events explicitly mapped with round-trip uncertainty", "events": report]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
    static var report: [[String: Any]] {
        storage.lock.lock(); defer { storage.lock.unlock() }
        return storage.events.sorted { ($0["time"] as? Double ?? 0) < ($1["time"] as? Double ?? 0) }
    }
}
