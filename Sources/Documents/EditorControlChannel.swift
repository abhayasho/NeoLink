import Foundation
import Darwin

/// One bounded, ordered local connection to the editor. Blocking socket I/O lives on
/// its own serial queue, never the main thread or Swift's cooperative executor.
/// A failed/ambiguous request is not replayed (it may already have saved a file).
final class EditorControlChannel: @unchecked Sendable {
    enum Failure: LocalizedError {
        case unavailable, timeout, disconnected, oversized
        var errorDescription: String? {
            switch self {
            case .unavailable: return "The editor control connection is unavailable."
            case .timeout: return "The editor did not respond in time. The command was not retried."
            case .disconnected: return "The editor control connection closed. The command was not retried."
            case .oversized: return "The editor control message exceeded its size limit."
            }
        }
    }
    private let worker = DispatchQueue(label: "com.neolink.editor.control", qos: .userInitiated)
    private var descriptor: Int32 = -1
    private var received = Data()
    private let path: String
    init(path: String) { self.path = path }

    final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Data, Error>?
        private var continuation: CheckedContinuation<Data, Error>?
        fileprivate func finish(_ result: Result<Data, Error>) {
            lock.lock()
            self.result = result
            let continuation = self.continuation; self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
        func value() async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result { lock.unlock(); continuation.resume(with: result) }
                else { self.continuation = continuation; lock.unlock() }
            }
        }
    }
    /// Enqueue synchronously so a warm selection leaves before SwiftUI lays out
    /// the new tab state. The dedicated worker still serializes every exchange.
    func submit(_ data: Data, timeout: Double = 8, traceToken: UInt64 = 0) -> Reply {
        let reply = Reply()
        worker.async {
            do {
                SelectionTrace.mark(traceToken, "socket.begin")
                let response = try self.exchange(data, timeout: timeout)
                SelectionTrace.mark(traceToken, "socket.received")
                reply.finish(.success(response))
            } catch { self.disconnect(); reply.finish(.failure(error)) }
        }
        return reply
    }
    func request(_ data: Data, timeout: Double = 8, traceToken: UInt64 = 0) async throws -> Data {
        try await submit(data, timeout: timeout, traceToken: traceToken).value()
    }
    func close() { worker.async { self.disconnect() } }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
    private func disconnect() {
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
        received.removeAll(keepingCapacity: false)
    }
    private func exchange(_ data: Data, timeout: Double) throws -> Data {
        guard data.count <= 1024 * 1024 else { throw Failure.oversized }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        if descriptor < 0 {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8CString)
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.unavailable }
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                bytes.withUnsafeBytes { destination.copyBytes(from: $0) }
            }
            descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw Failure.unavailable }
            var yes: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
            _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
            let status = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if status != 0 {
                guard errno == EINPROGRESS else { throw Failure.unavailable }
                try ready(POLLOUT, deadline: deadline)
                var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw Failure.unavailable }
            }
        }
        var message = data; message.append(10)
        try message.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try ready(POLLOUT, deadline: deadline)
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR || errno == EAGAIN { continue }
                guard count > 0 else { throw Failure.disconnected }
                offset += count
            }
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            guard received.count <= 2 * 1024 * 1024 else { throw Failure.oversized }
            if let newline = received.firstIndex(of: 10) {
                let response = Data(received[..<newline]); received.removeSubrange(...newline)
                return response
            }
            try ready(POLLIN, deadline: deadline)
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { throw Failure.disconnected }
            received.append(contentsOf: buffer.prefix(count))
        }
    }
    private func ready(_ event: Int32, deadline: Double) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw Failure.timeout }
            var fd = pollfd(fd: descriptor, events: Int16(event), revents: 0)
            let result = poll(&fd, 1, Int32(min(remaining * 1000 + 1, Double(Int32.max))))
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { throw Failure.timeout }
            if fd.revents & Int16(event) != 0 { return }
            throw Failure.disconnected
        }
    }
}
