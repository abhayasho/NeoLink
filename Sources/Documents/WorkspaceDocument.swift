import AppKit
import PDFKit
import SSHClient

enum DocumentSource: Equatable {
    case local(URL)
    case remote(endpoint: String, path: String)

    var displayPath: String {
        switch self {
        case .local(let url): return url.path
        case .remote(let endpoint, let path): return "\(endpoint)/\(path)"
        }
    }
}

/// Owns each file's native view so selection, scroll position, and undo survive tab changes.
@MainActor
final class WorkspaceDocument: NSObject, ObservableObject, Identifiable, NSTextViewDelegate {
    let id = UUID()
    let source: DocumentSource
    let title: String
    let browserTabID: UUID?
    let neovim: NeovimSession?
    var usesNeovim: Bool { neovim != nil }
    @Published private(set) var language = ""
    @Published private(set) var languageServers = ""
    @Published private(set) var diagnosticCount = 0
    @Published private(set) var isLoading = true
    @Published private(set) var isSaving = false
    @Published private(set) var isModified = false
    @Published private(set) var loaded: LoadedDocument?
    @Published var error: String?
    @Published private(set) var pageLabel = ""

    private let loader: () async throws -> LoadedDocument
    private var loadTask: Task<Void, Never>?
    private var isClosed = false
    private var originalData = Data()
    private var savedText = ""
    private(set) var text = ""
    private(set) var editor: NSScrollView?
    private(set) var pdfView: PDFView?
    private var pageObserver: NSObjectProtocol?
    private let textUndoManager = UndoManager()
    private var undoObservers: [NSObjectProtocol] = []

    var isReadOnly: Bool {
        if case .remote = source { return true }
        return loaded?.isPDF == true
    }

    var icon: String { title.lowercased().hasSuffix(".pdf") ? "doc.richtext" : "doc.text" }

    init(url: URL, browserTabID: UUID?, neovim: NeovimSession? = nil) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        source = .local(url)
        title = url.lastPathComponent
        self.browserTabID = browserTabID
        self.neovim = neovim
        loader = { try await Task.detached(priority: .userInitiated) { try DocumentFileIO.read(url) }.value }
        super.init()
    }

    init(item: SftpItem, connection: SSHConnection, endpoint: String, browserTabID: UUID?) {
        source = .remote(endpoint: endpoint, path: (item.path as NSString).standardizingPath)
        title = item.name
        self.browserTabID = browserTabID
        self.neovim = nil
        loader = {
            let limit = DocumentFileIO.sizeLimit(for: item.name)
            guard item.size ?? 0 <= UInt64(limit) else { throw DocumentFileError.tooLarge }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NeoLink-preview-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent((item.name as NSString).lastPathComponent)
            try await SftpManager.shared.downloadFile(connection: connection, item: item, to: url, maximumBytes: UInt64(limit))
            return try await Task.detached(priority: .userInitiated) { try DocumentFileIO.read(url) }.value
        }
        super.init()
    }

    func load() {
        guard loadTask == nil, !isClosed else { return }
        isLoading = true
        error = nil
        if let neovim, case .local(let url) = source {
            loadTask = Task { [weak self] in
                do {
                    try await Task.detached(priority: .userInitiated) {
                        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                        guard values.isRegularFile == true else { throw DocumentFileError.unsupported }
                        guard (values.fileSize ?? 0) <= 128 * 1024 * 1024 else {
                            throw NSError(domain: "NeoLink", code: 1, userInfo: [NSLocalizedDescriptionKey: "This file exceeds the 128 MB editor limit."])
                        }
                    }.value
                    guard let self, !self.isClosed else { return }
                    if !(await neovim.request(["method":"open", "path":url.path])) { self.error = neovim.error }
                } catch { self?.error = error.localizedDescription }
                self?.isLoading = false
                self?.loadTask = nil
            }
            return
        }
        loadTask = Task { [weak self, loader] in
            do {
                let result = try await loader()
                guard let self, !self.isClosed else { return }
                self.originalData = result.data
                self.text = result.text ?? ""
                self.savedText = self.text
                if result.isPDF {
                    guard let pdf = PDFDocument(data: result.data), pdf.pageCount > 0 || pdf.isLocked else {
                        throw DocumentFileError.invalidPDF
                    }
                    let view = PDFView()
                    view.backgroundColor = NSColor(NeoLinkTheme.editorBackground)
                    view.displayMode = .singlePageContinuous
                    view.autoScales = true
                    view.document = pdf
                    self.pdfView = view
                    self.pageObserver = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
                        Task { @MainActor in self?.updatePageLabel() }
                    }
                    self.updatePageLabel()
                }
                self.loaded = result
            } catch {
                if let self, !self.isClosed { self.error = error.localizedDescription }
            }
            guard let self, !self.isClosed else { return }
            self.isLoading = false
            self.loadTask = nil
        }
    }

    func updateText(_ value: String) {
        guard !isReadOnly, !isClosed else { return }
        text = value
        let modified = value != savedText
        if isModified != modified { isModified = modified }
    }

    func textDidChange(_ notification: Notification) {
        guard let view = notification.object as? NSTextView else { return }
        updateText(view.string)
    }

    func refreshFromDiskIfUnmodified() async {
        guard case .local = source, !usesNeovim, !isClosed, !isLoading, !isSaving, !isModified,
              loaded?.text != nil else { return }
        let baseline = originalData
        do {
            let result = try await loader()
            guard !isClosed, !isLoading, !isSaving, !isModified, originalData == baseline,
                  result.data != baseline, let text = result.text else { return }
            self.text = text
            savedText = text
            originalData = result.data
            loaded = result
            error = nil
            if let view = editor?.documentView as? NSTextView {
                let selection = view.selectedRange()
                view.string = text
                let length = (text as NSString).length
                let location = min(selection.location, length)
                view.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
            }
            textUndoManager.removeAllActions()
        } catch {
            if !isClosed { self.error = error.localizedDescription }
        }
    }

    func undoManager(for view: NSTextView) -> UndoManager? { textUndoManager }

    func update(from snapshot: NeovimBufferSnapshot) {
        if isModified != snapshot.modified { isModified = snapshot.modified }
        if language != snapshot.filetype { language = snapshot.filetype }
        if languageServers != snapshot.servers { languageServers = snapshot.servers }
        if diagnosticCount != snapshot.diagnostics { diagnosticCount = snapshot.diagnostics }
    }

    func finishAdoptingBuffer() { isLoading = false }

    func navigate(toLine line: Int) async {
        await loadTask?.value
        guard !isClosed, error == nil else { return }
        if let neovim, case .local(let url) = source {
            await neovim.request(["method":"open", "path":url.path, "line":line])
        } else if let view = makeEditor().documentView as? NSTextView {
            let string = view.string as NSString
            var location = 0
            for _ in 1..<max(1, line) {
                if location >= string.length { break }
                location = NSMaxRange(string.lineRange(for: NSRange(location: location, length: 0)))
            }
            view.setSelectedRange(NSRange(location: location, length: 0))
            view.scrollRangeToVisible(view.selectedRange())
        }
    }

    @discardableResult
    func save() async -> Bool {
        if let neovim, case .local(let url) = source {
            guard !isSaving, !isClosed else { return false }
            isSaving = true
            error = nil
            defer { isSaving = false }
            let result = await neovim.save(url)
            if !result { error = neovim.error }
            else { NotificationCenter.default.post(name: .neoLinkFileSaved, object: url) }
            return result
        }
        guard !isSaving, !isClosed, !isReadOnly, let format = loaded?.format, case .local(let url) = source else { return false }
        guard isModified else { return true }
        isSaving = true
        error = nil
        let snapshot = text
        let original = originalData
        defer { isSaving = false }
        do {
            originalData = try await Task.detached(priority: .userInitiated) {
                try DocumentFileIO.save(snapshot, format: format, to: url, originalData: original)
            }.value
            savedText = snapshot
            isModified = text != savedText
            NotificationCenter.default.post(name: .neoLinkFileSaved, object: url)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func saveCopy() {
        guard let format = loaded?.format else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = title
        panel.prompt = "Save Copy"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            if case .local(let sourceURL) = self.source, url.resolvingSymlinksInPath() == sourceURL {
                self.error = "Choose a different filename for the copy."
                return
            }
            let text = self.text
            Task {
                do {
                    try await Task.detached(priority: .userInitiated) { try format.encode(text).write(to: url, options: .atomic) }.value
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    func makeEditor() -> NSScrollView {
        if let editor { return editor }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.isRichText = false
        view.isEditable = !isReadOnly
        view.allowsUndo = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.font = .monospacedSystemFont(ofSize: TextSizePreferences.shared.pointSize, weight: .regular)
        view.textColor = NSColor(NeoLinkTheme.textPrimary)
        view.backgroundColor = NSColor(NeoLinkTheme.editorBackground)
        view.insertionPointColor = NSColor(NeoLinkTheme.accent)
        view.selectedTextAttributes = [.backgroundColor: NSColor(NeoLinkTheme.selection)]
        view.textContainerInset = NSSize(width: 16, height: 14)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = true
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.containerSize = view.maxSize
        view.textContainer?.widthTracksTextView = false
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = ("    " as NSString).size(withAttributes: [.font: view.font!]).width
        view.defaultParagraphStyle = style
        view.string = text
        view.delegate = self
        undoObservers = [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange].map { name in
            NotificationCenter.default.addObserver(forName: name, object: textUndoManager, queue: .main) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    if let view { self?.updateText(view.string) }
                }
            }
        }
        view.setAccessibilityLabel("\(title) editor")
        scroll.documentView = view
        editor = scroll
        return scroll
    }

    private func updatePageLabel() {
        guard let view = pdfView, let pdf = view.document else { return }
        if pdf.isLocked { pageLabel = "Password-protected PDF"; return }
        let page = view.currentPage.map { pdf.index(for: $0) + 1 } ?? 1
        pageLabel = "Page \(page) of \(pdf.pageCount)"
    }

    func close() {
        if let neovim, case .local(let url) = source { neovim.closeBuffer(url) }
        isClosed = true
        loadTask?.cancel()
        loadTask = nil
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
        pageObserver = nil
        (editor?.documentView as? NSTextView)?.delegate = nil
        textUndoManager.removeAllActions()
        undoObservers.forEach(NotificationCenter.default.removeObserver)
        undoObservers = []
        editor = nil
        pdfView = nil
    }

    deinit {
        loadTask?.cancel()
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
        undoObservers.forEach(NotificationCenter.default.removeObserver)
    }
}
