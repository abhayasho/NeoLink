import Foundation

extension MsgPackValue {
    var uint64Value: UInt64? {
        switch self {
        case .int(let value): return UInt64(exactly: value)
        case .uint(let value): return value
        default: return nil
        }
    }
}

/// Ordered facts from the editor's UI channel. Frames, selection echoes and buffer
/// notices travel on one connection, so their relative order is exactly Neovim's.
enum NativeGridItem: Sendable {
    case frame(GridFrame)
    /// `neolink_selection`: sent after the redraw (and its flush) that displayed `path` for `token`.
    case selection(token: UInt64, path: String)
    /// `neolink_leave`: the screen the host holds right now is `path`'s, in `mode`.
    case leave(path: String, mode: String, popupVisible: Bool, diagnostics: Bool)
    /// `neolink_touch`: a buffer that is not displayed changed (path "" means every cached image).
    case touch(path: String)
    case closed(String)
}

/// A lock-protected queue between the reader queue and the main actor. Adjacent frames merge,
/// so a hidden editor holds at most one pending frame regardless of how long it stays hidden.
final class GridMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [NativeGridItem] = []

    /// Returns true when the mailbox was empty, so the consumer needs waking.
    @discardableResult
    func push(_ item: NativeGridItem) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let wasEmpty = items.isEmpty
        if case .frame(let new) = item, case .frame(let old)? = items.last {
            items[items.count - 1] = .frame(old.merging(new))
        } else {
            items.append(item)
        }
        return wasEmpty
    }
    func drain() -> [NativeGridItem] {
        lock.lock(); defer { lock.unlock() }
        let result = items
        items.removeAll(keepingCapacity: true)
        return result
    }
    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return items.isEmpty }
}

/// The native Neovim UI client. Connects to the editor's `--listen` socket as an
/// `ext_linegrid` UI, decodes msgpack-RPC on its own queue, maintains the authoritative
/// grid model there and publishes immutable frames through `mailbox`.
final class NeovimGridClient: @unchecked Sendable {
    enum SetupError: LocalizedError {
        case unsupported(String)
        var errorDescription: String? { if case .unsupported(let reason) = self { return reason }; return nil }
    }

    let mailbox = GridMailbox()
    /// Called on the reader queue when the mailbox goes from empty to non-empty.
    var onWake: (@Sendable () -> Void)?
    private let rpc: NeovimRPCConnection
    private let model = NeovimGridModel()   // owned by the reader queue
    private(set) var framesReceived = 0     // reader queue only; diagnostic
    private(set) var channel: Int?

    init(socketPath: String) { rpc = NeovimRPCConnection(path: socketPath) }

    /// Connects, verifies `ext_linegrid`, registers with the editor configuration and attaches.
    func attach(cols: Int, rows: Int) async throws {
        rpc.onNotification = { [weak self] method, params in self?.handle(method, params) }
        rpc.onClose = { [weak self] failure in self?.publish(.closed(failure.localizedDescription)) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try self.rpc.connect(); continuation.resume() } catch { continuation.resume(throwing: error) }
            }
        }
        let info = try await rpc.request("nvim_get_api_info", [])
        guard case .array(let parts) = info, parts.count == 2, let channel = parts[0].intValue else {
            throw SetupError.unsupported("Neovim returned unexpected API information.")
        }
        let options = Set(parts[1]["ui_options"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        guard options.contains("ext_linegrid"), options.contains("rgb") else {
            throw SetupError.unsupported("This Neovim does not support ext_linegrid.")
        }
        self.channel = channel
        let attached = try await rpc.request("nvim_exec_lua", [.string("return NeoLink ~= nil and NeoLink.attach_ui(...)"), .array([.int(Int64(channel))])])
        guard attached.boolValue == true else { throw SetupError.unsupported("The editor configuration does not support a native UI.") }
        _ = try await rpc.request("nvim_ui_attach", [.int(Int64(max(1, cols))), .int(Int64(max(1, rows))),
                                                     .map([MsgPackPair(.string("rgb"), .bool(true)), MsgPackPair(.string("ext_linegrid"), .bool(true))])])
    }

    /// Foundation and libuv spell macOS /private/var aliases differently; the host compares paths
    /// from its documents, so resolve them here (reader queue, off the main thread).
    private func normalized(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        if let known = resolvedPaths[path] { return known }
        let value = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        if resolvedPaths.count > 256 { resolvedPaths.removeAll() }
        resolvedPaths[path] = value
        return value
    }
    private var resolvedPaths: [String: String] = [:]   // reader queue only

    private func publish(_ item: NativeGridItem) {
        if mailbox.push(item) { onWake?() }
    }

    private func handle(_ method: String, _ params: [MsgPackValue]) {
        switch method {
        case "redraw":
            for event in params {
                guard case .array(let items) = event, let name = items.first?.stringValue else { continue }
                if name == "flush" {
                    if let frame = model.takeFrame() { framesReceived += 1; publish(.frame(frame)) }
                } else {
                    model.apply(redraw: [event])
                }
            }
        case "neolink_selection":
            if params.count >= 2, let token = params[0].uint64Value, let path = params[1].stringValue { publish(.selection(token: token, path: normalized(path))) }
        case "neolink_leave":
            if params.count >= 4, let path = params[0].stringValue, let mode = params[1].stringValue {
                publish(.leave(path: normalized(path), mode: mode, popupVisible: params[2].boolValue ?? true, diagnostics: params[3].boolValue ?? true))
            }
        case "neolink_touch":
            publish(.touch(path: normalized(params.first?.stringValue ?? "")))
        default: break
        }
    }

    // MARK: Input. All of these are ordered notifications on the UI connection.

    func input(_ keys: String) { guard !keys.isEmpty else { return }; rpc.notify("nvim_input", [.string(keys)]) }
    func mouse(button: String, action: String, modifier: String, row: Int, column: Int) {
        rpc.notify("nvim_input_mouse", [.string(button), .string(action), .string(modifier), .int(0), .int(Int64(row)), .int(Int64(column))])
    }
    func paste(_ text: String) { rpc.notify("nvim_paste", [.string(text), .bool(true), .int(-1)]) }
    func resize(cols: Int, rows: Int) { rpc.notify("nvim_ui_try_resize", [.int(Int64(max(1, cols))), .int(Int64(max(1, rows)))]) }
    func detach() {
        rpc.notify("nvim_ui_detach", [])
        rpc.close()
    }
}
