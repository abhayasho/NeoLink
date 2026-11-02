import Foundation
import Darwin

struct ACPFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// ACP stdio uses one JSON-RPC object per line, not LSP Content-Length framing.
struct ACPLineFramer {
    private var buffer = Data()
    static let limit = 8 * 1024 * 1024
    mutating func append(_ data: Data) throws -> [[String: Any]] {
        buffer.append(data)
        var messages: [[String: Any]] = []
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]
            guard line.count <= Self.limit else { throw ACPFailure(message: "Agent message exceeds the 8 MB limit.") }
            if !line.isEmpty {
                guard let value = try JSONSerialization.jsonObject(with: line) as? [String: Any], value["jsonrpc"] as? String == "2.0" else {
                    throw ACPFailure(message: "The executable did not return ACP JSON-RPC messages. Use an ACP adapter, or Terminal mode for a regular CLI.")
                }
                messages.append(value)
            }
            buffer.removeSubrange(...end)
        }
        guard buffer.count <= Self.limit else { throw ACPFailure(message: "Agent message exceeds the 8 MB limit.") }
        return messages
    }
    var hasPartialMessage: Bool { !buffer.isEmpty }
}

@MainActor
final class ACPTransport {
    var onMessage: (([String: Any]) -> Void)?
    var onDisconnect: ((String) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private let writer = DispatchQueue(label: "NeoLink.ACP.write")
    private(set) var stderrTail = ""
    private(set) var isRunning = false

    func start(_ agent: CodingAgent, directory: URL) throws {
        guard !isRunning else { return }
        guard agent.isValid, let executable = CommandRunner.executable(agent.executable) else {
            throw ACPFailure(message: "ACP executable not found. Install the adapter and select its full path in the launcher.")
        }
        let process = Process(), stdin = Pipe(), stdout = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = agent.arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = home + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = errors
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        isRunning = true
        let reader = stdout.fileHandleForReading
        Task.detached { [weak self] in
            defer { try? reader.close() }
            var framer = ACPLineFramer()
            do {
                while await self?.isRunning == true {
                    let chunk = try Self.readChunk(reader)
                    if chunk.isEmpty { break }
                    for message in try framer.append(chunk) { await self?.receive(message) }
                }
                await self?.finish(framer.hasPartialMessage ? "The agent closed a partial protocol message." : "Agent disconnected.")
            } catch { await self?.finish(error.localizedDescription) }
        }
        let errorReader = errors.fileHandleForReading
        Task.detached { [weak self] in
            defer { try? errorReader.close() }
            while await self?.isRunning == true, let chunk = try? Self.readChunk(errorReader), !chunk.isEmpty {
                await self?.appendError(chunk)
            }
        }
    }

    nonisolated private static func readChunk(_ handle: FileHandle) throws -> Data {
        // FileHandle.read(upToCount:) may wait to fill its count on a pipe.
        // A single POSIX read returns currently available bytes for streaming.
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        var count: Int
        repeat { count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count) } while count < 0 && errno == EINTR
        guard count >= 0 else { throw ACPFailure(message: "Agent pipe closed.") }
        return Data(bytes.prefix(count))
    }

    private func appendError(_ data: Data) { stderrTail = String((stderrTail + String(decoding: data, as: UTF8.self)).suffix(8192)) }

    func request(_ method: String, _ params: [String: Any], timeout: Double = 30) async throws -> [String: Any] {
        guard isRunning else { throw ACPFailure(message: "Agent is disconnected.") }
        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            deadlines[id] = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) } catch { return }
                // A timed-out prompt cannot safely overlap another prompt. Close the transport.
                self?.finish("The agent did not respond to \(method) in time. Reconnect to try again.")
            }
            send(["jsonrpc":"2.0", "id":id, "method":method, "params":params])
        }
    }

    func notify(_ method: String, _ params: [String: Any]) {
        send(["jsonrpc":"2.0", "method":method, "params":params])
    }
    func reply(id: Any, result: [String: Any]) { send(["jsonrpc":"2.0", "id":id, "result":result]) }
    func reject(id: Any, code: Int = -32601, message: String = "Client method not supported") {
        send(["jsonrpc":"2.0", "id":id, "error":["code":code,"message":message]])
    }

    private func send(_ message: [String: Any]) {
        guard isRunning, let input else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed])
            guard data.count <= ACPLineFramer.limit else { throw ACPFailure(message: "Outgoing ACP message is too large.") }
            data.append(10)
            writer.async { [weak self] in
                do { try input.write(contentsOf: data) }
                catch { Task { @MainActor in self?.finish("Could not send to agent: \(error.localizedDescription)") } }
            }
        } catch { finish(error.localizedDescription) }
    }

    private func receive(_ message: [String: Any]) {
        guard isRunning else { return }
        if message["method"] != nil { onMessage?(message); return }
        guard let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) else { return }
        deadlines.removeValue(forKey: id)?.cancel()
        if let error = message["error"] as? [String: Any] {
            continuation.resume(throwing: ACPFailure(message: error["message"] as? String ?? "Agent request failed."))
        } else if let result = message["result"] as? [String: Any] { continuation.resume(returning: result) }
        else { continuation.resume(throwing: ACPFailure(message: "Invalid agent response.")) }
    }

    func close() { finish("Session closed.", notify: false) }
    private func finish(_ message: String, notify: Bool = true) {
        guard isRunning else { return }
        isRunning = false
        deadlines.values.forEach { $0.cancel() }; deadlines.removeAll()
        let waiting = pending.values; pending.removeAll()
        waiting.forEach { $0.resume(throwing: ACPFailure(message: message)) }
        if let input { writer.async { try? input.close() } }
        input = nil
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        self.process = nil
        if notify { onDisconnect?(message) }
    }
}
