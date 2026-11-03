import AppKit

struct TerminalTab: Identifiable, Equatable {
    let id: UUID
    var title: String
    let configuration: TerminalConfiguration
    let state: TerminalState
    let agentName: String?

    init(id: UUID = UUID(), title: String, configuration: TerminalConfiguration, currentDirectory: String? = nil, agentName: String? = nil) {
        self.id = id
        self.title = title
        self.configuration = configuration
        self.state = TerminalState(currentDirectory: currentDirectory)
        self.agentName = agentName
    }

    static func == (lhs: TerminalTab, rhs: TerminalTab) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.configuration == rhs.configuration
    }
}

enum WorkspaceTab: Identifiable {
    case terminal(TerminalTab)
    case document(WorkspaceDocument)

    var id: UUID {
        switch self {
        case .terminal(let tab): return tab.id
        case .document(let document): return document.id
        }
    }

    var title: String {
        switch self {
        case .terminal(let tab): return tab.title
        case .document(let document): return document.title
        }
    }

    var terminal: TerminalTab? {
        if case .terminal(let tab) = self { return tab }
        return nil
    }

    var document: WorkspaceDocument? {
        if case .document(let document) = self { return document }
        return nil
    }
}

@MainActor
final class TabsController: ObservableObject {
    @Published var tabs: [WorkspaceTab]
    @Published var selectedTabID: UUID? {
        didSet {
            guard selectedTabID != oldValue else { return }
            if tabs.first(where: { $0.id == oldValue })?.terminal?.agentName != nil { fileRefreshRevision += 1 }
            guard let document = selectedTab?.document, case .local(let url) = document.source else {
                codeSession.prepareSelection(nil)
                return
            }
            if !document.usesNeovim {
                codeSession.prepareSelection(nil)
                Task { await document.refreshFromDiskIfUnmodified() }
                return
            }
            codeSession.prepareSelection(url.path)
            if !document.isLoading { codeSession.select(url.path) }
        }
    }
    @Published private(set) var isConfirmingClose = false
    @Published private(set) var fileRefreshRevision = 0
    @Published private(set) var explorerDiagnostics: [String: ExplorerDiagnostics] = [:]
    @Published var showAgentPanel = true
    @Published var agentPanelTabID: UUID?
    @Published private(set) var dockedAgentIDs: Set<UUID> = []
    @Published private(set) var acpSessions: [ACPSession] = []
    @Published var selectedACPID: UUID?
    var focusedACPID: UUID?
    let codeSession: NeovimSession

    init(useNeovim: Bool = true) {
        codeSession = NeovimSession(executable: useNeovim ? CommandRunner.executable("nvim") : nil)
        let initial = TerminalTab(
            title: "Local",
            configuration: TerminalConfiguration(backend: .localShell),
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
        tabs = [.terminal(initial)]
        selectedTabID = initial.id
        codeSession.onSnapshot = { [weak self] snapshot in self?.syncEditor(snapshot) }
        codeSession.onEditorFocus = { [weak self] in
            guard let self, (!self.agentPanelTabs.isEmpty || !self.acpSessions.isEmpty) else { return }
            self.refreshAgentEdits()
        }
        codeSession.selectedPath = { [weak self] in
            guard let document = self?.selectedTab?.document, document.usesNeovim, case .local(let url) = document.source else { return nil }
            return url.path
        }
    }

    func openTab(title: String, configuration: TerminalConfiguration) {
        guard !isConfirmingClose else { return }
        let directory: String?
        if configuration.backend == .localShell {
            directory = FileManager.default.homeDirectoryForCurrentUser.path
        } else {
            directory = nil
        }
        let tab = TerminalTab(title: title, configuration: configuration, currentDirectory: directory)
        tabs.append(.terminal(tab))
        selectedTabID = tab.id
    }

    func openLocalTab() {
        openTab(title: "Local", configuration: TerminalConfiguration(backend: .localShell))
    }

    func openTerminal(in directory: URL) {
        guard !isConfirmingClose else { return }
        let tab = TerminalTab(title: directory.lastPathComponent, configuration: TerminalConfiguration(backend: .localShell), currentDirectory: directory.path)
        tabs.append(.terminal(tab)); selectedTabID = tab.id
    }

    func openREPL(_ executable: String, in directory: URL) {
        guard !isConfirmingClose, ["python3", "node", "swift", "irb", "lua"].contains(executable) else { return }
        let command = CodingAgent(name: "\(executable) REPL", executable: executable,
                                  arguments: executable == "swift" ? ["repl"] : [])
        let tab = TerminalTab(title: "\(executable) REPL", configuration: TerminalConfiguration(backend: .localShell,
                              startupCommand: command.launchCommand(in: directory)), currentDirectory: directory.path)
        tabs.append(.terminal(tab)); selectedTabID = tab.id
    }

    func openAgent(_ agent: CodingAgent, in directory: URL, docked: Bool = true) throws {
        guard !isConfirmingClose else { return }
        guard agent.isValid else { throw AgentLaunchError.invalidCommand }
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            throw AgentLaunchError.missingDirectory
        }
        let configuration = TerminalConfiguration(backend: .localShell, startupCommand: agent.launchCommand(in: directory))
        let tab = TerminalTab(title: agent.name, configuration: configuration,
                              currentDirectory: directory.path, agentName: agent.name)
        tabs.append(.terminal(tab))
        if docked {
            selectedACPID = nil
            dockedAgentIDs.insert(tab.id)
            agentPanelTabID = tab.id
            showAgentPanel = true
        } else { selectedTabID = tab.id }
    }

    func openACP(_ agent: CodingAgent, in directory: URL, mcpServers: [[String: Any]] = []) throws {
        guard !isConfirmingClose else { return }
        guard agent.isValid else { throw AgentLaunchError.invalidCommand }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { throw AgentLaunchError.missingDirectory }
        let session = ACPSession(agent: agent, directory: root, mcpServers: mcpServers)
        session.onTurnFinished = { [weak self] in self?.refreshAgentEdits() }
        acpSessions.append(session); selectedACPID = session.id; showAgentPanel = true
        session.connect()
    }

    var selectedACP: ACPSession? { acpSessions.first { $0.id == selectedACPID } }
    var agentSelection: String {
        get { selectedACPID.map { "acp:" + $0.uuidString } ?? agentPanelTabID.map { "terminal:" + $0.uuidString } ?? "" }
        set {
            if newValue.hasPrefix("acp:") { selectedACPID = UUID(uuidString: String(newValue.dropFirst(4))) }
            else { selectedACPID = nil; agentPanelTabID = UUID(uuidString: String(newValue.dropFirst(9))) }
        }
    }
    func closeACP(_ id: UUID) {
        acpSessions.first(where: { $0.id == id })?.close()
        acpSessions.removeAll { $0.id == id }
        if selectedACPID == id { selectedACPID = acpSessions.last?.id }
        refreshAgentEdits()
    }
    func shutdownAgents() { acpSessions.forEach { $0.close() }; acpSessions = [] }

    func refreshAgentEdits() {
        fileRefreshRevision += 1
        guard let document = selectedTab?.document else { return }
        if document.usesNeovim, case .local(let url) = document.source {
            Task { await codeSession.request(["method":"open", "path":url.path]) }
        } else { Task { await document.refreshFromDiskIfUnmodified() } }
    }

    enum AgentLaunchError: LocalizedError {
        case invalidCommand, missingDirectory
        var errorDescription: String? {
            switch self {
            case .invalidCommand: return "Enter an agent name and a valid executable."
            case .missingDirectory: return "This project folder is unavailable. Choose another folder."
            }
        }
    }

    var selectedRunner: String? {
        guard let document = selectedTab?.document, case .local(let url) = document.source else { return nil }
        let names = ["py":"python3", "js":"node", "mjs":"node", "swift":"swift", "sh":"bash", "rb":"ruby", "lua":"lua", "go":"go"]
        return names[url.pathExtension.lowercased()].flatMap(CommandRunner.executable)
    }

    func runSelectedFile() {
        guard let document = selectedTab?.document, case .local(let url) = document.source, let runner = selectedRunner else { return }
        Task {
            if document.usesNeovim, !(await codeSession.refresh()) { return }
            if document.isModified, !(await document.save()) { return }
            openLocalTab()
            let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let go = url.pathExtension.lowercased() == "go" ? " run " : " "
            selectedTerminalTab?.state.pendingCommand = "cd -- \(quote(url.deletingLastPathComponent().path)) && \(quote(runner))\(go)\(quote(url.path))\n"
        }
    }

    func openDocument(_ document: WorkspaceDocument) {
        guard !isConfirmingClose else { return }
        if let existing = tabs.first(where: { $0.document?.source == document.source }) {
            selectedTabID = existing.id
            return
        }
        tabs.append(.document(document))
        selectedTabID = document.id
        document.load()
    }

    func openFile(_ url: URL) {
        PhaseTrace.mark("open.begin")
        let engine = codeSession.executable != nil && NeovimSession.supports(url) ? codeSession : nil
        // Start the editor engine first, so Neovim boots while SwiftUI builds the new tab
        // (about 40 ms on the main thread) instead of after it. Later opens reuse it.
        engine?.start()
        openDocument(WorkspaceDocument(url: url, browserTabID: browserTab?.id, neovim: engine))
        PhaseTrace.mark("open.end")
    }

    private func syncEditor(_ snapshot: NeovimSnapshot) {
        let counts = Dictionary(snapshot.buffers.filter { !codeSession.closedPaths.contains($0.path) }.map {
            ($0.path, ExplorerDiagnostics(errors: $0.errors ?? 0, warnings: $0.warnings ?? 0))
        }, uniquingKeysWith: { _, latest in latest })
        if explorerDiagnostics != counts { explorerDiagnostics = counts }
        let documents = Dictionary(tabs.compactMap { tab -> (String, WorkspaceDocument)? in
            guard let document = tab.document, case .local(let url) = document.source else { return nil }
            return (url.path, document)
        }, uniquingKeysWith: { first, _ in first })
        for buffer in snapshot.buffers where !codeSession.closedPaths.contains(buffer.path) {
            let url = URL(fileURLWithPath: buffer.path)
            if let document = documents[buffer.path] {
                if document.isModified && !buffer.modified { fileRefreshRevision &+= 1 }
                document.update(from: buffer)
            } else {
                let document = WorkspaceDocument(url: url, browserTabID: browserTab?.id, neovim: codeSession)
                document.update(from: buffer)
                tabs.append(.document(document))
                document.finishAdoptingBuffer()
            }
        }
        if selectedTab?.document?.usesNeovim == true, selectedTab?.document?.isLoading == false, !isConfirmingClose, codeSession.canAdoptSelection(snapshot),
           let active = tabs.first(where: { $0.document?.source == .local(URL(fileURLWithPath: snapshot.active)) }), active.id != selectedTabID {
            selectedTabID = active.id
        }
    }

    func requestCloseTab(_ tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        approveClosing(tab.document.map { [$0] } ?? []) { [weak self] approved in
            if approved { self?.closeTab(tabID, discardingChanges: true) }
        }
    }

    func approveClosingAll(completion: @escaping (Bool) -> Void) {
        approveClosing(tabs.compactMap(\.document), all: true, completion: completion)
    }

    private func approveClosing(_ documents: [WorkspaceDocument], all: Bool = false, completion: @escaping (Bool) -> Void) {
        guard !isConfirmingClose else { completion(false); return }
        isConfirmingClose = true
        Task { @MainActor in
            defer { isConfirmingClose = false }
            var editorUnavailable = false
            if documents.contains(where: \.usesNeovim) {
                if !(await codeSession.refresh()) {
                    let alert = NSAlert()
                    alert.messageText = "The coding engine is unavailable"
                    alert.informativeText = "NeoLink cannot verify or save its unsaved buffers. Close anyway? Files already saved on disk are unaffected."
                    alert.addButton(withTitle: "Keep Open")
                    alert.addButton(withTitle: "Close Anyway")
                    guard alert.runModal() == .alertSecondButtonReturn else { completion(false); return }
                    editorUnavailable = true
                }
                if !editorUnavailable, codeSession.snapshot?.unnamedModified == true {
                    let alert = NSAlert()
                    alert.messageText = "Save your unnamed Neovim buffer first"
                    alert.informativeText = "Use :write followed by a filename in the editor, then close again."
                    alert.runModal()
                    completion(false)
                    return
                }
            }
            for document in all ? tabs.compactMap(\.document) : documents {
                if editorUnavailable && document.usesNeovim { continue }
                guard !document.isSaving else { completion(false); return }
                guard document.isModified else { continue }
                selectedTabID = document.id
                let alert = NSAlert()
                alert.messageText = "Save changes to “\(document.title)”?"
                alert.informativeText = "Your changes will be lost if you close without saving."
                alert.addButton(withTitle: "Save")
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Don’t Save")
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    guard await document.save() else { completion(false); return }
                case .alertThirdButtonReturn: break
                default: completion(false); return
                }
            }
            isConfirmingClose = false
            completion(true)
        }
    }

    func closeTab(_ tabID: UUID, discardingChanges: Bool = false) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        guard discardingChanges || tabs[index].document?.isModified != true else { return }
        let wasAgent = tabs[index].terminal?.agentName != nil
        tabs[index].terminal?.state.close()
        tabs[index].document?.close()
        tabs.remove(at: index)
        dockedAgentIDs.remove(tabID)
        if agentPanelTabID == tabID { agentPanelTabID = agentPanelTabs.last?.id }
        if workspaceTabs.isEmpty {
            openLocalTab()
        } else if selectedTabID == tabID {
            // Keep the user's place in the strip instead of jumping to its first tab.
            selectedTabID = workspaceTabs[min(index, workspaceTabs.count - 1)].id
        }
        if wasAgent { fileRefreshRevision += 1 }
    }

    func selectNextTab() { selectTab(offset: 1) }
    func selectPreviousTab() { selectTab(offset: -1) }

    private func selectTab(offset: Int) {
        let tabs = workspaceTabs
        guard !isConfirmingClose, !tabs.isEmpty else { return }
        let index = tabs.firstIndex(where: { $0.id == selectedTabID }) ?? 0
        selectedTabID = tabs[(index + offset + tabs.count) % tabs.count].id
    }

    var selectedTab: WorkspaceTab? {
        tabs.first(where: { $0.id == selectedTabID })
    }

    var terminalTabs: [TerminalTab] { tabs.compactMap(\.terminal) }
    var workspaceTabs: [WorkspaceTab] { tabs.filter { !dockedAgentIDs.contains($0.id) } }
    var workspaceTerminalTabs: [TerminalTab] { workspaceTabs.compactMap(\.terminal) }
    var agentPanelTabs: [TerminalTab] { terminalTabs.filter { dockedAgentIDs.contains($0.id) } }
    var selectedTerminalTab: TerminalTab? { selectedTab?.terminal }

    // Keep the originating browser visible while a file is open beside its terminal.
    var browserTab: TerminalTab? {
        selectedTerminalTab
            ?? terminalTabs.first(where: { $0.id == selectedTab?.document?.browserTabID })
            ?? terminalTabs.first
    }
}
