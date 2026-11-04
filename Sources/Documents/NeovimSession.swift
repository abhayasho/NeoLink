import AppKit
import SwiftUI
import SwiftTerm
import Darwin
import QuartzCore

struct NeovimBufferSnapshot: Decodable {
    let path: String
    let modified: Bool
    let filetype: String
    let servers: String
    let diagnostics: Int
    var errors: Int? = nil
    var warnings: Int? = nil
}

struct NeovimSnapshot: Decodable {
    let revision: Int
    let buffers: [NeovimBufferSnapshot]
    let active: String
    let mode: String
    let unnamedModified: Bool
    var selection: UInt64? = nil
    var notice: String? = nil
}

@MainActor
final class NeovimSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    let executable: String?
    @Published private(set) var isStarted = false
    @Published private(set) var isReady = false
    @Published private(set) var mode = "Insert"
    @Published var error: String?
    private(set) var snapshot: NeovimSnapshot?
    @Published private(set) var requestedPath: String?
    private(set) var closedPaths: Set<String> = []
    var onSnapshot: ((NeovimSnapshot) -> Void)?
    var selectedPath: (() -> String?)?
    var onEditorFocus: (() -> Void)?
    private(set) var terminal: CodeTerminalView?
    private var directory: URL?
    private var watcher: DispatchSourceFileSystemObject?
    private var startup: Task<Void, Never>?
    private var requestChain: Task<Void, Never>?
    private var queuedCommands = 0
    weak var host: NeovimHostView?
    private var control: EditorControlChannel?
    private var epoch = UUID()
    private var selection: UInt64 = 0
    private let statusWorker = DispatchQueue(label: "com.neolink.editor.status", qos: .userInitiated)
    private var readingStatus = false
    private var statusPending = false
    private(set) var skippedSelections = 0
    private(set) var dispatchedRequests = 0
    private(set) var parsedSelection: UInt64 = 0
    private(set) var presentedSelection: (token: UInt64, time: Double)?
    private var selectionBegan = 0.0
    private var lastNotice = ""
    var recordsSelectionSamples = false
    private(set) var selectionSamples: [Double] = []
    func selectionPresented(_ token: UInt64, at time: Double) {
        guard token == selection, token == parsedSelection, time > 0 else { return }
        if presentedSelection?.token != token {
            SelectionTrace.mark(token, "presented", at: time)
            presentedSelection = (token, time)
            if recordsSelectionSamples, time >= selectionBegan {
                selectionSamples.append(time - selectionBegan)
                if selectionSamples.count > 200 { selectionSamples.removeFirst(selectionSamples.count - 200) }
            }
        }
    }

    init(executable: String? = CommandRunner.executable("nvim")) {
        self.executable = executable
        super.init()
    }

    static let extensions: Set<String> = ["swift","py","pyi","js","jsx","ts","tsx","mjs","cjs","c","h","cpp","cc","cxx","hpp","m","mm","rs","go","java","kt","kts","rb","php","lua","vim","el","sh","bash","zsh","fish","html","htm","css","scss","sass","less","json","jsonc","yaml","yml","toml","xml","svg","md","mdx","txt","tex","sql","r","rmd","jl","dart","zig","nix","conf","ini","cfg","env","gitignore","gitattributes","editorconfig","cmake","svelte","vue","ipynb","log"]
    static func supports(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased()) || ["Makefile","Dockerfile","Gemfile","Rakefile","CMakeLists.txt","LICENSE","README",".gitignore",".zshrc",".bashrc",".env",".editorconfig"].contains(url.lastPathComponent)
    }

    static var configurationURL: URL {
        if let resource = Bundle.main.url(forResource: "neolink", withExtension: "lua", subdirectory: "Editor") { return resource }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Editor/neolink.lua")
    }

    func start() {
        guard !isStarted, let executable else { return }
        PhaseTrace.mark("editor.start")
        do {
            // Unix-domain socket paths have a short length limit on macOS.
            let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("neolink-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            self.directory = directory
            control = EditorControlChannel(path: directory.appendingPathComponent("control.sock").path)
            let descriptor = Darwin.open(directory.path, O_EVTONLY)
            if descriptor >= 0 {
                let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write], queue: .main)
                watcher.setEventHandler { [weak self] in self?.readPublishedState() }
                watcher.setCancelHandler { Darwin.close(descriptor) }
                watcher.resume()
                self.watcher = watcher
            }
            let terminal = PhaseTrace.measure("editor.viewCreation") { CodeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500)) }
            terminal.session = self
            terminal.onActivate = { [weak self] in self?.onEditorFocus?() }
            terminal.processDelegate = self
            TerminalAppearance.apply(to: terminal)
            terminal.observeTextSize()
            self.terminal = terminal
            var environment = ProcessInfo.processInfo.environment
            environment["TERM"] = "xterm-256color"
            environment["COLORTERM"] = "truecolor"
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
            environment["NEOLINK_STATUS_FILE"] = directory.appendingPathComponent("status.json").path
            environment["NEOLINK_CONTROL_SOCKET"] = directory.appendingPathComponent("control.sock").path
            let state = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NeoLink/EditorState", isDirectory: true)
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            environment["XDG_STATE_HOME"] = state.path
            PhaseTrace.measure("editor.spawn") {
                terminal.startProcess(executable: executable,
                    args: ["--noplugin", "-u", Self.configurationURL.path, "-i", "NONE", "--listen", directory.appendingPathComponent("editor.sock").path],
                    environment: environment.map { "\($0.key)=\($0.value)" },
                    currentDirectory: WorkspaceAccess.shared.projectURL?.path ?? FileManager.default.homeDirectoryForCurrentUser.path)
            }
            isStarted = true
            startup = Task { [weak self] in
                // status.json appears when Neovim has loaded neolink.lua (about 120 ms). A
                // 5 ms poll notices it within a frame; each check is one stat.
                for _ in 0..<1_000 {
                    guard !Task.isCancelled else { return }
                    if await Task.detached(priority: .userInitiated, operation: {
                        FileManager.default.fileExists(atPath: directory.appendingPathComponent("status.json").path)
                        && FileManager.default.fileExists(atPath: directory.appendingPathComponent("control.sock").path)
                    }).value {
                        PhaseTrace.mark("editor.neovimReady")
                        self?.readPublishedState()
                        self?.isReady = true
                        return
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                self?.error = "Neovim did not finish starting. Close and reopen NeoLink to retry."
            }
        } catch { self.error = error.localizedDescription }
    }

    private func readPublishedState() {
        guard let directory else { return }
        guard !readingStatus else { statusPending = true; return }
        readingStatus = true
        let token = epoch
        statusWorker.async { [weak self] in
            let state: NeovimSnapshot? = {
                guard let data = try? Data(contentsOf: directory.appendingPathComponent("status.json")), data.count < 1024 * 1024,
                      let raw = try? JSONDecoder().decode(NeovimSnapshot.self, from: data) else { return nil }
                return Self.normalized(raw)
            }()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.epoch == token else { return }
                self.readingStatus = false
                if let state { self.accept(state) }
                if self.statusPending { self.statusPending = false; self.readPublishedState() }
            }
        }
    }

    nonisolated static func normalized(_ raw: NeovimSnapshot) -> NeovimSnapshot {
        // Foundation and libuv spell macOS /private/var aliases differently. Resolve
        // paths off-main, once per distinct path in this snapshot.
        var paths: [String: String] = ["": ""]
        func normalize(_ path: String) -> String {
            if let cached = paths[path] { return cached }
            let value = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            paths[path] = value; return value
        }
        return NeovimSnapshot(revision: raw.revision, buffers: raw.buffers.map {
            NeovimBufferSnapshot(path: normalize($0.path), modified: $0.modified, filetype: $0.filetype, servers: $0.servers,
                                 diagnostics: $0.diagnostics, errors: $0.errors, warnings: $0.warnings)
        }, active: normalize(raw.active), mode: raw.mode, unnamedModified: raw.unnamedModified, selection: raw.selection, notice: raw.notice)
    }

    private func accept(_ state: NeovimSnapshot) {
        guard state.revision > (snapshot?.revision ?? -1) else { return }
        snapshot = state
        if let notice = state.notice, !notice.isEmpty, notice != lastNotice {
            lastNotice = notice; error = notice
        }
        let mode = state.mode.hasPrefix("i") ? "Insert" : (state.mode == "n" ? "Normal" : "Visual / Command")
        if self.mode != mode { self.mode = mode }
        onSnapshot?(state)
    }

    func selectionParsed(_ token: UInt64) {
        guard token == selection else { return }
        SelectionTrace.mark(token, "marker.recognized")
        parsedSelection = token
        guard requestedPath == selectedPath?() else { return }
        if requestedPath != nil { requestedPath = nil }
        host?.selectionReady(session: self)
    }

    @discardableResult
    func request(_ message: [String: Any]) async -> Bool { await enqueue(message).value }

    private func enqueue(_ message: [String: Any]) -> Task<Bool, Never> {
        if message["method"] as? String == "open", let path = message["path"] as? String {
            closedPaths.remove(path)
        }
        start()
        // Enqueue before awaiting startup: saves/closes cannot overtake a cold open.
        let preceding = queuedCommands > 0 ? requestChain : nil, startup = startup, token = epoch
        let traceToken = message["selectionOnly"] as? UInt64 ?? selection
        SelectionTrace.mark(traceToken, "command.enqueued")
        var immediate: EditorControlChannel.Reply?
        let immediateSent = CACurrentMediaTime()
        if queuedCommands == 0, isReady, let control,
           message["selectionOnly"] as? UInt64 == selection,
           let path = message["path"] as? String, path == selectedPath?(), !closedPaths.contains(path) {
            var dispatch = message
            dispatch.removeValue(forKey: "selectionOnly")
            dispatch["activate"] = true; dispatch["selection"] = selection
            if SelectionTrace.enabled { dispatch["trace"] = true }
            if let data = try? JSONSerialization.data(withJSONObject: dispatch) {
                SelectionTrace.mark(traceToken, "command.queueReady")
                SelectionTrace.mark(traceToken, "command.dispatched", at: immediateSent)
                immediate = control.submit(data, traceToken: traceToken)
                dispatchedRequests += 1
            }
        }
        queuedCommands += 1
        let task = Task { @MainActor [weak self] () -> Bool in
            defer { if let self { self.queuedCommands -= 1 } }
            await preceding?.value
            await startup?.value
            guard let self, self.epoch == token, self.isReady, let control = self.control else { return false }
            do {
                SelectionTrace.mark(traceToken, "command.queueReady")
                var message = message
                let opening = message["method"] as? String == "open"
                if opening, let path = message["path"] as? String {
                    if self.closedPaths.contains(path) { return false }
                    let active = self.selectedPath.map { path == $0() } ?? true
                    if let requested = message.removeValue(forKey: "selectionOnly") as? UInt64,
                       immediate == nil && (!active || requested != self.selection) {
                        SelectionTrace.mark(traceToken, "command.skipped")
                        self.skippedSelections += 1
                        return true
                    }
                    message["activate"] = active
                    if active { message["selection"] = self.selection }
                }
                if SelectionTrace.enabled { message["trace"] = true }
                let data = try JSONSerialization.data(withJSONObject: message)
                if opening { PhaseTrace.mark("editor.openRequest.begin") }
                if immediate == nil { self.dispatchedRequests += 1 }
                let sent = immediate == nil ? CACurrentMediaTime() : immediateSent
                SelectionTrace.mark(traceToken, "command.dispatched", at: sent)
                let output: Data
                if let immediate { output = try await immediate.value() }
                else { output = try await control.request(data, traceToken: traceToken) }
                let received = CACurrentMediaTime()
                SelectionTrace.mark(traceToken, "command.acknowledged", at: received)
                if opening { PhaseTrace.mark("editor.openRequest.end") }
                struct Response: Decodable { let ok: Bool; let error: String; let state: NeovimSnapshot; let trace: [String: Double]? }
                let response = try await Task.detached(priority: .userInitiated) {
                    let value = try JSONDecoder().decode(Response.self, from: output)
                    return Response(ok: value.ok, error: value.error, state: Self.normalized(value.state), trace: value.trace)
                }.value
                guard self.epoch == token else { return false }
                if let times = response.trace { SelectionTrace.remote(traceToken, times, sent: SelectionTrace.time(traceToken, "socket.begin") ?? sent,
                                         received: SelectionTrace.time(traceToken, "socket.received") ?? received) }
                SelectionTrace.mark(traceToken, "metadata.accept")
                self.accept(response.state)
                if !response.ok { self.error = response.error }
                return response.ok
            } catch {
                if self.epoch == token { self.error = error.localizedDescription }
                return false
            }
        }
        requestChain = Task { _ = await task.value }
        return task
    }

    func select(_ path: String) {
        let token = selection
        _ = enqueue(["method": "open", "path": path, "selectionOnly": token])
    }

    func action(_ name: String) { _ = enqueue(["method":"action", "action":name]) }
    func prepareSelection(_ path: String?) {
        selection &+= 1
        selectionBegan = CACurrentMediaTime()
        SelectionTrace.mark(selection, "selection.begin", at: selectionBegan)
        if let event = NSApp?.currentEvent, [.leftMouseDown, .leftMouseUp, .keyDown].contains(event.type),
           selectionBegan - event.timestamp >= 0, selectionBegan - event.timestamp < 0.5 {
            SelectionTrace.mark(selection, "input.event", at: event.timestamp, fields: ["type": event.type.rawValue])
        }
        host?.selectionChanging()
        if requestedPath != path { requestedPath = path }
    }
    var selectionToken: UInt64 { selection }
    func canAdoptSelection(_ state: NeovimSnapshot) -> Bool {
        requestedPath == nil && (state.selection == nil || state.selection == selection)
    }
    func closeBuffer(_ url: URL) {
        closedPaths.insert(url.path)
        _ = enqueue(["method":"close", "path":url.path])
    }
    func save(_ url: URL) async -> Bool { await request(["method":"save", "path":url.path]) }
    func refresh() async -> Bool { await request(["method":"status"]) }

    func shutdown() {
        epoch = UUID()
        startup?.cancel()
        control?.close(); control = nil
        watcher?.cancel()
        watcher = nil
        terminal?.processDelegate = nil
        if terminal?.process.running == true { terminal?.terminate() }
        terminal = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        self.directory = nil
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard title.hasPrefix("neolink-selection:"), let token = UInt64(title.dropFirst("neolink-selection:".count)) else { return }
        if Thread.isMainThread { MainActor.assumeIsolated { selectionParsed(token) } }
        else { DispatchQueue.main.async { [weak self] in self?.selectionParsed(token) } }
    }
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            self?.isReady = false
            self?.error = "The coding engine exited. Close and reopen NeoLink to start it again."
        }
    }
}

final class CodeTerminalView: InteractiveTerminalView {
    weak var session: NeovimSession?
    @objc func undo(_ sender: Any?) { session?.action("undo") }
    @objc func redo(_ sender: Any?) { session?.action("redo") }
    @objc func selectCode(_ sender: Any?) { session?.action("selectAll") }
    override func copy(_ sender: Any) { session?.action("copy") }
    @objc func cut(_ sender: Any?) { session?.action("cut") }
    override func performFindPanelAction(_ sender: Any?) { session?.action("find") }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if let action = item.action, ["undo:", "redo:", "copy:", "cut:", "selectCode:"].contains(NSStringFromSelector(action)) { return true }
        return super.validateUserInterfaceItem(item)
    }
}

struct NeovimSurface: NSViewRepresentable {
    @ObservedObject var session: NeovimSession
    let active: Bool
    let selection: UUID?

    func makeNSView(context: Context) -> NeovimHostView { NeovimHostView() }
    func updateNSView(_ host: NeovimHostView, context: Context) {
        host.synchronize(session: session, active: active, selection: selection)
    }
}

final class NeovimHostView: NSView {
    private var terminal: CodeTerminalView?
    private var selection: UUID?
    private var wantsActive = false
    func selectionChanging() {
        if let terminal, !terminal.isHidden {
            if window?.firstResponder === terminal { window?.makeFirstResponder(nil) }
            terminal.isHidden = true
        }
    }
    func selectionReady(session: NeovimSession) {
        guard wantsActive, session.requestedPath == nil, session.selectedPath?() != nil else { return }
        terminal?.isHidden = false
        SelectionTrace.mark(session.selectionToken, "view.shown")
        if let terminal {
            SelectionTrace.mark(session.selectionToken, "focus.begin")
            window?.makeFirstResponder(terminal)
            SelectionTrace.mark(session.selectionToken, "focus.end")
        }
    }
    func synchronize(session: NeovimSession, active: Bool, selection: UUID?) {
        session.host = self
        wantsActive = active
        let active = active && session.requestedPath == nil
        let mounting = terminal == nil && session.terminal != nil
        if terminal == nil, let view = session.terminal { terminal = view; addSubview(view) }
        if !active, let terminal, !terminal.isHidden, let window, let responder = window.firstResponder as? NSView,
           responder === terminal || responder.isDescendant(of: terminal) {
            // Avoid AppKit's key-view search while SwiftUI is updating (see TerminalHostView).
            window.makeFirstResponder(nil)
        }
        if terminal?.isHidden != !active {
            SelectionTrace.mark(session.selectionToken, active ? "view.shown" : "view.hidden")
            terminal?.isHidden = !active
            if active { PhaseTrace.mark("editor.shown") }
        }
        if mounting { needsLayout = true }
        if active, terminal != nil, mounting || self.selection != selection {
            self.selection = selection
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selection == selection, let terminal = self.terminal, !terminal.isHidden else { return }
                SelectionTrace.mark(terminal.session?.selectionToken ?? 0, "focus.begin")
                self.window?.makeFirstResponder(terminal)
                SelectionTrace.mark(terminal.session?.selectionToken ?? 0, "focus.end")
                PhaseTrace.mark("editor.focused")
            }
        } else if !active { self.selection = nil }
    }
    override func layout() {
        super.layout()
        if bounds.width > 100, bounds.height > 40, terminal?.frame != bounds { SelectionTrace.mark(terminal?.session?.selectionToken ?? 0, "layout"); terminal?.frame = bounds }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let terminal, !terminal.isHidden { window?.makeFirstResponder(terminal) } }
}
