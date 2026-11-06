import Foundation
import Darwin

/// One persistent msgpack-RPC connection to Neovim's `--listen` socket.
///
/// Reads are event driven on a dedicated serial queue (a dispatch read source, never the
/// Swift cooperative pool and never the main thread). Writes are ordered on a second queue.
/// Notifications and responses are delivered on the read queue: callers hop to the main
/// actor themselves, with their own generation checks.
final class NeovimRPCConnection: @unchecked Sendable {
    enum Failure: LocalizedError, Equatable {
        case unavailable, timeout, disconnected, remote(String), protocolViolation
        var errorDescription: String? {
            switch self {
            case .unavailable: return "The editor connection is unavailable."
            case .timeout: return "The editor did not respond in time."
            case .disconnected: return "The editor connection closed."
            case .remote(let message): return message
            case .protocolViolation: return "The editor sent a malformed message."
            }
        }
    }

    private let path: String
    private let readQueue = DispatchQueue(label: "com.neolink.editor.rpc.read", qos: .userInteractive)
    private let writeQueue = DispatchQueue(label: "com.neolink.editor.rpc.write", qos: .userInteractive)
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private var stream = MsgPackStream()
    private let lock = NSLock()
    private var pending: [UInt32: CheckedContinuation<MsgPackValue, Error>] = [:]
    private var nextIdentifier: UInt32 = 1
    private var closed = false

    /// Called on the read queue, in wire order, for every notification.
    var onNotification: ((String, [MsgPackValue]) -> Void)?
    /// Called once, on the read queue, when the stream ends or becomes invalid.
    var onClose: ((Failure) -> Void)?
    private(set) var bytesReceived = 0

    init(path: String) { self.path = path }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    /// Blocking connect with a deadline. Call off the main thread.
    func connect(timeout: Double = 5) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.unavailable }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in bytes.withUnsafeBytes { destination.copyBytes(from: $0) } }
        let handle = socket(AF_UNIX, SOCK_STREAM, 0)
        guard handle >= 0 else { throw Failure.unavailable }
        var yes: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        _ = fcntl(handle, F_SETFL, O_NONBLOCK)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(handle, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if status != 0 {
            guard errno == EINPROGRESS else { Darwin.close(handle); throw Failure.unavailable }
            var fd = pollfd(fd: handle, events: Int16(POLLOUT), revents: 0)
            let remaining = max(1, Int32((deadline - ProcessInfo.processInfo.systemUptime) * 1000))
            guard poll(&fd, 1, remaining) > 0 else { Darwin.close(handle); throw Failure.timeout }
            var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(handle, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { Darwin.close(handle); throw Failure.unavailable }
        }
        descriptor = handle
        let source = DispatchSource.makeReadSource(fileDescriptor: handle, queue: readQueue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.resume()
        self.source = source
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                finish(.disconnected); return
            }
            if count == 0 { finish(.disconnected); return }
            bytesReceived += count
            do {
                try buffer.withUnsafeBufferPointer { try stream.append(UnsafeBufferPointer(rebasing: $0[0..<count])) }
                while let message = try stream.next() { dispatch(message) }
            } catch { finish(.protocolViolation); return }
            if count < buffer.count { return }
        }
    }

    private func dispatch(_ message: MsgPackValue) {
        guard case .array(let items) = message, let kind = items.first?.intValue else { return }
        switch kind {
        case 2: // notification [2, method, params]
            guard items.count == 3, let method = items[1].stringValue, let params = items[2].arrayValue else { return }
            onNotification?(method, params)
        case 1: // response [1, id, error, result]
            guard items.count == 4, let raw = items[1].intValue, let identifier = UInt32(exactly: raw) else { return }
            lock.lock(); let continuation = pending.removeValue(forKey: identifier); lock.unlock()
            if items[2].isNull { continuation?.resume(returning: items[3]) }
            else {
                let message = items[2].arrayValue?.dropFirst().first?.stringValue ?? items[2].stringValue ?? "Neovim reported an error."
                continuation?.resume(throwing: Failure.remote(message))
            }
        case 0: // request from Neovim: this client serves none.
            guard items.count == 4, let raw = items[1].intValue else { return }
            send(.array([.int(1), .int(Int64(raw)), .array([.int(0), .string("not supported")]), .null]))
        default: break
        }
    }

    private func finish(_ failure: Failure) {
        lock.lock()
        let already = closed; closed = true
        let waiting = pending; pending.removeAll()
        lock.unlock()
        for continuation in waiting.values { continuation.resume(throwing: failure) }
        guard !already else { return }
        source?.cancel(); source = nil
        onClose?(failure)
    }

    private func send(_ value: MsgPackValue) {
        let bytes = value.encoded
        writeQueue.async { [weak self] in self?.write(bytes) }
    }

    private func write(_ bytes: [UInt8]) {
        guard descriptor >= 0, !closed else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if count > 0 { offset += count; continue }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN {
                var fd = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let remaining = Int32(max(1, (deadline - ProcessInfo.processInfo.systemUptime) * 1000))
                if deadline > ProcessInfo.processInfo.systemUptime, poll(&fd, 1, remaining) > 0 { continue }
            }
            finish(.disconnected); return
        }
    }

    /// Fire-and-forget API call (the reply, if any, is dropped). Ordered with all other sends.
    func notify(_ method: String, _ params: [MsgPackValue]) {
        send(.array([.int(2), .string(method), .array(params)]))
    }

    func request(_ method: String, _ params: [MsgPackValue], timeout: Double = 8) async throws -> MsgPackValue {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MsgPackValue, Error>) in
            lock.lock()
            if closed { lock.unlock(); continuation.resume(throwing: Failure.disconnected); return }
            let identifier = nextIdentifier; nextIdentifier &+= 1
            pending[identifier] = continuation
            lock.unlock()
            send(.array([.int(0), .int(Int64(identifier)), .string(method), .array(params)]))
            readQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock(); let waiting = self.pending.removeValue(forKey: identifier); self.lock.unlock()
                waiting?.resume(throwing: Failure.timeout)
            }
        }
    }

    func close() {
        writeQueue.async { [weak self] in self?.finish(.disconnected) }
    }
}
