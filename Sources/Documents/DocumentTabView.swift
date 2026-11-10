import SwiftUI
import PDFKit

struct DocumentTabView: View {
    @ObservedObject var document: WorkspaceDocument

    var body: some View {
        let _ = LayoutTrace.body("DocumentTabView")
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(document.source.displayPath)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(document.source.displayPath)
                    .foregroundColor(NeoLinkTheme.textSecondary)
                Spacer(minLength: 0)
                if document.loaded?.isPDF == true {
                    pdfControls
                } else if document.loaded != nil {
                    TextSizeControl()
                    if !document.isReadOnly {
                        Button(document.isSaving ? "Saving…" : "Save") { Task { await document.save() } }
                            .disabled(!document.isModified || document.isSaving)
                            .help("Save file (⌘S)")
                    }
                    Button("Save Copy…", action: document.saveCopy)
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(NeoLinkTheme.panelBackground)
            NeoLinkTheme.horizontalSeparator()

            if let error = document.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).textSelection(.enabled)
                    Spacer()
                    if document.loaded != nil {
                        Button { document.error = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain)
                            .help("Dismiss error")
                    }
                }
                .font(.system(size: 12))
                .foregroundColor(NeoLinkTheme.warning)
                .padding(14)
                .background(NeoLinkTheme.warning.opacity(0.07))
            }

            if document.isLoading {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Opening \(document.title)…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if document.loaded != nil {
                DocumentNativeView(document: document)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: document.icon).font(.system(size: 32, weight: .light))
                    Text("Preview unavailable")
                    HStack {
                        Button("Try Again", action: document.load)
                        if case .local(let url) = document.source {
                            Button("Open in Default App") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            NeoLinkTheme.horizontalSeparator()
            HStack(spacing: 8) {
                if document.loaded?.isPDF == true {
                    Text(document.pageLabel)
                } else {
                    Text(document.isReadOnly ? "Remote preview · Read only" : (document.isModified ? "Unsaved changes" : "Saved"))
                    Spacer()
                    if let format = document.loaded?.format {
                        Text(format.encoding == .utf8 ? "UTF-8" : "UTF-16")
                    }
                    Text("⌘F  Find")
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(NeoLinkTheme.textSecondary)
            .padding(.horizontal, 14)
            .frame(height: 28)
        }
        .foregroundColor(NeoLinkTheme.textPrimary)
        .background(NeoLinkTheme.editorBackground)
    }

    private var pdfControls: some View {
        HStack(spacing: 10) {
            Button { document.pdfView?.goToPreviousPage(nil) } label: { Image(systemName: "chevron.up") }
                .help("Previous page").accessibilityLabel("Previous page")
            Button { document.pdfView?.goToNextPage(nil) } label: { Image(systemName: "chevron.down") }
                .help("Next page").accessibilityLabel("Next page")
            Button { document.pdfView?.zoomOut(nil) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out").accessibilityLabel("Zoom out")
            Button { document.pdfView?.zoomIn(nil) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in").accessibilityLabel("Zoom in")
            Button("Fit") { document.pdfView?.autoScales = true }
                .help("Fit PDF to available space")
        }
    }
}

private struct DocumentNativeView: NSViewRepresentable {
    @ObservedObject var document: WorkspaceDocument
    @ObservedObject private var textSize = TextSizePreferences.shared
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> DocumentHostView {
        DocumentHostView(content: document.pdfView ?? document.makeEditor())
    }

    func updateNSView(_ nsView: DocumentHostView, context: Context) {
        LayoutTrace.body("DocumentNativeView.update")
        if let editor = (nsView.content as? NSScrollView)?.documentView as? NSTextView {
            editor.isEditable = isEnabled && !document.isReadOnly && !document.isSaving
            if editor.font?.pointSize != textSize.pointSize {
                editor.font = .monospacedSystemFont(ofSize: textSize.pointSize, weight: .regular)
                let paragraph = NSMutableParagraphStyle()
                paragraph.tabStops = []
                paragraph.defaultTabInterval = ("    " as NSString).size(withAttributes: [.font: editor.font!]).width
                editor.defaultParagraphStyle = paragraph
            }
        }
    }
}

private final class DocumentHostView: NSView {
    let content: NSView

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        content.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder((self.content as? NSScrollView)?.documentView ?? self.content)
        }
    }
}
