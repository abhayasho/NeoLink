import AppKit
import SwiftUI
import SwiftTerm
import Darwin

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
        do {
            // Unix-domain socket paths have a short length limit on macOS.
            let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("neolink-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            self.directory = directory
            let descriptor = Darwin.open(directory.path, O_EVTONLY)
            if descriptor >= 0 {
                let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write], queue: .main)
                watcher.setEventHandler { [weak self] in self?.readPublishedState() }
                watcher.setCancelHandler { Darwin.close(descriptor) }
                watcher.resume()
                self.watcher = watcher
            }
            let terminal = CodeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
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
            let state = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NeoLink/EditorState", isDirectory: true)
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            environment["XDG_STATE_HOME"] = state.path
            terminal.startProcess(executable: executable,
                args: ["--noplugin", "-u", Self.configurationURL.path, "-i", "NONE", "--listen", directory.appendingPathComponent("editor.sock").path],
                environment: environment.map { "\($0.key)=\($0.value)" },
                currentDirectory: WorkspaceAccess.shared.projectURL?.path ?? FileManager.default.homeDirectoryForCurrentUser.path)
            isStarted = true
            startup = Task { [weak self] in
                for _ in 0..<200 {
                    guard !Task.isCancelled else { return }
                    if FileManager.default.fileExists(atPath: directory.appendingPathComponent("status.json").path) {
                        self?.readPublishedState()
                        self?.isReady = true
                        return
                    }
                    try? await Task.sleep(nanoseconds: 25_000_000)
                }
                self?.error = "Neovim did not finish starting. Close and reopen NeoLink to retry."
            }
        } catch { self.error = error.localizedDescription }
    }

    private func readPublishedState() {
        guard let directory,
              let data = try? Data(contentsOf: directory.appendingPathComponent("status.json")), data.count < 1024 * 1024,
              let state = try? JSONDecoder().decode(NeovimSnapshot.self, from: data) else { return }
        accept(state)
    }

    private func accept(_ raw: NeovimSnapshot) {
        // File notifications can arrive after a newer RPC response. Never replay old selection/dirty state.
        guard raw.revision > (snapshot?.revision ?? -1) else { return }
        // Foundation and libuv spell macOS /private/var aliases differently.
        let normalize: (String) -> String = { $0.isEmpty ? "" : URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
        let state = NeovimSnapshot(revision: raw.revision, buffers: raw.buffers.map {
            NeovimBufferSnapshot(path: normalize($0.path), modified: $0.modified, filetype: $0.filetype, servers: $0.servers, diagnostics: $0.diagnostics, errors: $0.errors, warnings: $0.warnings)
        }, active: normalize(raw.active), mode: raw.mode, unnamedModified: raw.unnamedModified)
        if requestedPath == state.active { requestedPath = nil }
        snapshot = state
        let mode = state.mode.hasPrefix("i") ? "Insert" : (state.mode == "n" ? "Normal" : "Visual / Command")
        if self.mode != mode { self.mode = mode }
        onSnapshot?(state)
    }

    @discardableResult
    func request(_ message: [String: Any]) async -> Bool {
        if message["method"] as? String == "open", let path = message["path"] as? String {
            closedPaths.remove(path)
        }
        start()
        await startup?.value
        guard isReady, let executable, let directory else { return false }
        // Serialize commands so a slow open cannot overtake the following save or close.
        let preceding = requestChain
        let task = Task { @MainActor [weak self] () -> Bool in
            await preceding?.value
            guard let self else { return false }
            do {
                var message = message
                if message["method"] as? String == "open", let path = message["path"] as? String, let selectedPath = self.selectedPath {
                    message["activate"] = path == selectedPath()
                }
                let data = try JSONSerialization.data(withJSONObject: message)
                let json = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "'", with: "''")
                let expression = "luaeval('NeoLink.dispatch(_A)', '\(json)')"
                let result = try await CommandRunner.run(executable, ["--server", directory.appendingPathComponent("editor.sock").path, "--remote-expr", expression], timeout: 8)
                struct Response: Decodable { let ok: Bool; let error: String; let state: NeovimSnapshot }
                guard result.status == 0 else { throw NSError(domain: "Neovim", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: String(decoding: result.output, as: UTF8.self)]) }
                let response = try JSONDecoder().decode(Response.self, from: result.output)
                self.accept(response.state)
                if !response.ok { self.error = response.error }
                return response.ok
            } catch {
                self.error = error.localizedDescription
                return false
            }
        }
        requestChain = Task { _ = await task.value }
        return await task.value
    }

    func action(_ name: String) { Task { await request(["method":"action", "action":name]) } }
    func prepareSelection(_ path: String) { requestedPath = path }
    func closeBuffer(_ url: URL) {
        closedPaths.insert(url.path)
        Task { await request(["method":"close", "path":url.path]) }
    }
    func save(_ url: URL) async -> Bool { await request(["method":"save", "path":url.path]) }
    func refresh() async -> Bool { await request(["method":"status"]) }

    func shutdown() {
        startup?.cancel()
        watcher?.cancel()
        watcher = nil
        terminal?.processDelegate = nil
        if terminal?.process.running == true { terminal?.terminate() }
        terminal = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        self.directory = nil
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
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
    func synchronize(session: NeovimSession, active: Bool, selection: UUID?) {
        let mounting = terminal == nil && session.terminal != nil
        if terminal == nil, let view = session.terminal { terminal = view; addSubview(view) }
        if !active, let terminal, !terminal.isHidden, let window, let responder = window.firstResponder as? NSView,
           responder === terminal || responder.isDescendant(of: terminal) {
            // Avoid AppKit's key-view search while SwiftUI is updating (see TerminalHostView).
            window.makeFirstResponder(nil)
        }
        if terminal?.isHidden != !active { terminal?.isHidden = !active }
        needsLayout = true
        if active, terminal != nil, mounting || self.selection != selection {
            self.selection = selection
            DispatchQueue.main.async { [weak self] in
                guard let self, let terminal = self.terminal, !terminal.isHidden else { return }
                self.window?.makeFirstResponder(terminal)
            }
        } else if !active { self.selection = nil }
    }
    override func layout() {
        super.layout()
        if bounds.width > 100, bounds.height > 40, terminal?.frame != bounds { terminal?.frame = bounds }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let terminal, !terminal.isHidden { window?.makeFirstResponder(terminal) } }
}
