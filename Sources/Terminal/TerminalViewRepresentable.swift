import SwiftUI
import SwiftTerm
import AppKit

enum TerminalBackend: Equatable {
    case localShell
    case ssh(host: String, username: String, port: Int)
}

struct TerminalConfiguration: Equatable {
    let backend: TerminalBackend
}

enum TerminalProcessStatus: Equatable {
    case idle
    case running
    case exited(Int32?)
}

/// A tab owns its terminal, including its scrollback and process, for the lifetime of the tab.
/// The native terminal host keeps launched views mounted while switching tabs.
final class TerminalState: NSObject, ObservableObject, LocalProcessTerminalViewDelegate, @unchecked Sendable {
    @Published var currentDirectory: String?
    @Published var terminalTitle: String?
    @Published private(set) var processStatus: TerminalProcessStatus = .idle

    /// Kept compatible with file-browser actions. Commands go directly to this tab's process,
    /// even if SwiftUI has switched to a different terminal before its next view update.
    var pendingCommand: String? {
        didSet { sendPendingCommandIfPossible() }
    }

    private var terminalView: LocalProcessTerminalView?
    private var shellIntegration: TerminalShellIntegration?
    private(set) var isClosed = false
    var hasStarted: Bool { terminalView != nil }

    init(currentDirectory: String? = nil) {
        self.currentDirectory = currentDirectory
        super.init()
    }

    func view(for configuration: TerminalConfiguration, initialSize: NSSize) -> LocalProcessTerminalView {
        if let terminalView { return terminalView }

        let view = LocalProcessTerminalView(frame: NSRect(origin: .zero, size: initialSize))
        view.processDelegate = self
        view.nativeBackgroundColor = NSColor(NeoLinkTheme.editorBackground)
        view.nativeForegroundColor = NSColor(NeoLinkTheme.textPrimary)
        view.caretColor = NSColor(NeoLinkTheme.accent)
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView = view

        guard !isClosed else { return view }
        let environment = TerminalEnvironment.values()
        switch configuration.backend {
        case .localShell:
            let integration = try? TerminalShellIntegration()
            shellIntegration = integration
            view.startProcess(
                executable: "/bin/zsh",
                args: ["-l"],
                environment: integration?.environment(base: environment) ?? environment,
                currentDirectory: currentDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
            )
        case .ssh(let host, let username, let port):
            var args: [String] = []
            if port != 22 { args.append(contentsOf: ["-p", String(port)]) }
            args.append("\(username)@\(host)")
            view.startProcess(executable: "/usr/bin/ssh", args: args, environment: environment)
        }

        // Publishing while SwiftUI is making an NSView triggers a view-update warning.
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view, !self.isClosed, self.terminalView === view,
                  self.processStatus == .idle else { return }
            self.processStatus = view.process.running ? .running : .exited(nil)
        }
        sendPendingCommandIfPossible()
        return view
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        pendingCommand = nil
        terminalView?.processDelegate = nil
        if terminalView?.process.running == true { terminalView?.terminate() }
        terminalView = nil
        shellIntegration = nil
    }

    deinit {
        terminalView?.processDelegate = nil
        if terminalView?.process.running == true { terminalView?.terminate() }
    }

    private func sendPendingCommandIfPossible() {
        guard !isClosed, let command = pendingCommand, !command.isEmpty,
              let process = terminalView?.process, process.running else { return }
        pendingCommand = nil
        process.send(data: ArraySlice(command.utf8))
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isClosed else { return }
            let title = title.isEmpty ? nil : title
            if self.terminalTitle != title { self.terminalTitle = title }
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        let directory = Self.directoryPath(from: directory)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isClosed, self.currentDirectory != directory else { return }
            self.currentDirectory = directory
        }
    }

    /// OSC 7 reports a file URL; file browsers and the status bar need its decoded path.
    static func directoryPath(from directory: String?) -> String? {
        guard let directory, !directory.isEmpty else { return nil }
        if directory.hasPrefix("/") { return directory }
        guard let url = URL(string: directory), url.isFileURL, !url.path.isEmpty else { return nil }
        return url.path
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isClosed else { return }
            self.processStatus = .exited(exitCode)
        }
    }
}

enum TerminalEnvironment {
    /// Keep tools and SSH agent access inherited from the app while setting terminal capabilities.
    static func values(
        inherited: [String: String] = ProcessInfo.processInfo.environment,
        terminalDefaults: [String] = Terminal.getEnvironmentVariables()
    ) -> [String] {
        var values = inherited
        for entry in terminalDefaults {
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
        }
        values["TERM_PROGRAM"] = "NeoLink"
        return values.keys.sorted().map { "\($0)=\(values[$0]!)" }
    }
}

/// Adds OSC 7 directory reports without editing the user's shell configuration.
/// Forwarding startup files keeps login-shell setup, including custom ZDOTDIR changes.
final class TerminalShellIntegration {
    let directory: URL
    private let originalDotDirectory: String?

    init(originalDotDirectory: String? = ProcessInfo.processInfo.environment["ZDOTDIR"]) throws {
        self.originalDotDirectory = originalDotDirectory
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NeoLink-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            for (name, script) in Self.scripts {
                try script.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func environment(base: [String]) -> [String] {
        let overridden = ["ZDOTDIR=", "NEOLINK_ORIGINAL_ZDOTDIR=", "NEOLINK_ORIGINAL_ZDOTDIR_SET=", "TERM_PROGRAM="]
        var result = base.filter { entry in !overridden.contains(where: { entry.hasPrefix($0) }) }
        result.append("TERM_PROGRAM=NeoLink")
        result.append("ZDOTDIR=\(directory.path)")
        result.append("NEOLINK_ORIGINAL_ZDOTDIR_SET=\(originalDotDirectory == nil ? 0 : 1)")
        result.append("NEOLINK_ORIGINAL_ZDOTDIR=\(originalDotDirectory ?? "")")
        return result
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    private static let restoreUserDirectory = #"""
    if [[ "$_neolink_user_zdotdir_set" == 1 ]]; then
        ZDOTDIR="$_neolink_user_zdotdir"
    else
        unset ZDOTDIR
    fi
    """#

    private static let saveUserDirectory = #"""
    typeset -g _neolink_user_zdotdir="${ZDOTDIR:-$HOME}"
    typeset -g _neolink_user_zdotdir_set="${+ZDOTDIR}"
    if [[ -o rcs ]]; then
        ZDOTDIR="$_neolink_integration_dir"
    fi
    """#

    private static let scripts: [String: String] = [
        ".zshenv": #"""
        typeset -g _neolink_integration_dir="$ZDOTDIR"
        if [[ "${NEOLINK_ORIGINAL_ZDOTDIR_SET:-0}" == 1 ]]; then
            ZDOTDIR="$NEOLINK_ORIGINAL_ZDOTDIR"
        else
            unset ZDOTDIR
        fi
        unset NEOLINK_ORIGINAL_ZDOTDIR NEOLINK_ORIGINAL_ZDOTDIR_SET
        if [[ -r "${ZDOTDIR:-$HOME}/.zshenv" ]]; then
            builtin source "${ZDOTDIR:-$HOME}/.zshenv"
        fi
        """# + "\n" + saveUserDirectory,
        ".zprofile": restoreUserDirectory + "\n" + #"""
        if [[ -r "${ZDOTDIR:-$HOME}/.zprofile" ]]; then
            builtin source "${ZDOTDIR:-$HOME}/.zprofile"
        fi
        """# + "\n" + saveUserDirectory,
        ".zshrc": restoreUserDirectory + "\n" + #"""
        # macOS /etc/zshrc chooses HISTFILE before the user's .zshrc runs.
        if [[ "$HISTFILE" == "$_neolink_integration_dir/.zsh_history" ]]; then
            HISTFILE="${ZDOTDIR:-$HOME}/.zsh_history"
        fi
        if [[ -r "${ZDOTDIR:-$HOME}/.zshrc" ]]; then
            builtin source "${ZDOTDIR:-$HOME}/.zshrc"
        fi
        function _neolink_report_cwd() {
            local LC_ALL=C
            local url_path='' character hex
            local -i index
            for (( index = 1; index <= ${#PWD}; ++index )); do
                character="$PWD[index]"
                if [[ "$character" == [A-Za-z0-9/._~-] ]]; then
                    url_path+="$character"
                else
                    builtin printf -v hex '%%%02X' "'$character"
                    url_path+="$hex"
                fi
            done
            builtin printf '\e]7;file://%s%s\a' "${HOST:-localhost}" "$url_path"
        }
        autoload -Uz add-zsh-hook
        add-zsh-hook precmd _neolink_report_cwd
        add-zsh-hook chpwd _neolink_report_cwd
        """#
    ]
}

struct TerminalViewRepresentable: NSViewRepresentable {
    let tabs: [TerminalTab]
    let selectedTabID: UUID?

    func makeNSView(context: Context) -> TerminalHostView {
        TerminalHostView(frame: .zero)
    }

    func updateNSView(_ nsView: TerminalHostView, context: Context) {
        nsView.synchronize(tabs: tabs, selectedTabID: selectedTabID)
    }
}

/// SwiftTerm reflows its buffer on every frame-size change, including a zero-size detach.
/// Keep launched views mounted and hide inactive terminals instead of replacing the NSView.
final class TerminalHostView: NSView {
    private var tabs: [TerminalTab] = []
    private var selectedTabID: UUID?
    private var mountedViews: [UUID: LocalProcessTerminalView] = [:]
    private var focusedTabID: UUID?
    private let makeTerminalView: (TerminalTab, NSSize) -> LocalProcessTerminalView

    init(frame: NSRect, makeTerminalView: @escaping (TerminalTab, NSSize) -> LocalProcessTerminalView = { tab, size in
        tab.state.view(for: tab.configuration, initialSize: size)
    }) {
        self.makeTerminalView = makeTerminalView
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func synchronize(tabs: [TerminalTab], selectedTabID: UUID?) {
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        let openIDs = Set(tabs.map(\.id))
        for id in Array(mountedViews.keys) where !openIDs.contains(id) {
            mountedViews.removeValue(forKey: id)?.removeFromSuperview()
        }
        layoutTerminals()
    }

    override func layout() {
        super.layout()
        layoutTerminals()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutTerminals()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            focusedTabID = nil
            layoutTerminals()
        }
    }

    private func layoutTerminals() {
        // SwiftUI can briefly propose zero during layout. Keep the last terminal grid intact.
        guard bounds.width >= 100, bounds.height >= 40 else { return }
        if let tab = tabs.first(where: { $0.id == selectedTabID }), mountedViews[tab.id] == nil {
            let view = makeTerminalView(tab, bounds.size)
            mountedViews[tab.id] = view
            addSubview(view)
        }
        for (id, view) in mountedViews {
            view.isHidden = id != selectedTabID
            if id == selectedTabID, view.frame != bounds { view.frame = bounds }
        }
        guard focusedTabID != selectedTabID, let id = selectedTabID, let view = mountedViews[id] else { return }
        focusedTabID = id
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, self.selectedTabID == id, let view, let window = self.window else { return }
            window.makeFirstResponder(view)
        }
    }
}
