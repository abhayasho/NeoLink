import Foundation
import Darwin

/// Bounded subprocesses; cancelling a search also stops its worker process.
enum CommandRunner {
    struct Result { let status: Int32; let output: Data; let truncated: Bool }
    private final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        func start(_ process: Process) throws {
            lock.lock(); defer { lock.unlock() }
            if cancelled { throw CancellationError() }
            try process.run()
            self.process = process
        }
        func stop() {
            lock.lock(); cancelled = true; let process = self.process; lock.unlock()
            if let process, process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
    }

    static func executable(_ name: String) -> String? {
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return paths.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(_ executable: String, _ arguments: [String], directory: URL? = nil, timeout: Double = 15, maximumBytes: Int = 8 * 1024 * 1024) async throws -> Result {
        let control = Control()
        return try await withTaskCancellationHandler {
            let result = try await Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.currentDirectoryURL = directory
                let output = Pipe()
                process.standardOutput = output
                process.standardError = output
                process.standardInput = FileHandle.nullDevice
                try control.start(process)
                let deadline = DispatchWorkItem { control.stop() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                defer { deadline.cancel(); try? output.fileHandleForReading.close() }
                var data = Data()
                var truncated = false
                while let chunk = try output.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    if data.count + chunk.count > maximumBytes {
                        data.append(chunk.prefix(max(0, maximumBytes - data.count)))
                        truncated = true
                        control.stop()
                        break
                    }
                    data.append(chunk)
                }
                process.waitUntilExit()
                return Result(status: process.terminationStatus, output: data, truncated: truncated)
            }.value
            try Task.checkCancellation()
            return result
        } onCancel: { control.stop() }
    }
}
