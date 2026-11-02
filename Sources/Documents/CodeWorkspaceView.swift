import SwiftUI

struct CodeWorkspaceView: View {
    @ObservedObject var session: NeovimSession
    @ObservedObject var controller: TabsController
    private var document: WorkspaceDocument? { controller.selectedTab?.document }

    var body: some View {
        VStack(spacing: 0) {
            if let document, document.usesNeovim {
                CodeToolbar(document: document, session: session, controller: controller)
                CodeDocumentStatus(document: document)
            }
            if let error = session.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).textSelection(.enabled).lineLimit(4)
                    Spacer()
                    Button { session.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.font(.system(size: 11)).foregroundColor(NeoLinkTheme.warning).padding(10)
            }
            NeovimSurface(session: session, active: document?.usesNeovim == true && !controller.isConfirmingClose && session.isReady && session.requestedPath == nil, selection: document?.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 10) {
                Text("Neovim · \(session.mode)")
                Spacer()
                Text("Esc  Normal mode   ·   i  Insert   ·   ⌘S  Save")
            }.font(.system(size: 10)).foregroundColor(NeoLinkTheme.textSecondary).padding(.horizontal, 12).frame(height: 22)
        }.background(NeoLinkTheme.editorBackground)
    }
}

private struct CodeDocumentStatus: View {
    @ObservedObject var document: WorkspaceDocument
    var body: some View {
        if let error = document.error {
            Text(error).font(.system(size: 11)).foregroundColor(NeoLinkTheme.warning).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
    }
}

private struct CodeToolbar: View {
    @ObservedObject var document: WorkspaceDocument
    @ObservedObject var session: NeovimSession
    @ObservedObject var controller: TabsController

    var body: some View {
        HStack(spacing: 8) {
            Text(document.language.isEmpty ? "Text" : document.language.capitalized)
                .lineLimit(1).help(document.source.displayPath)
            if document.isLoading { ProgressView().controlSize(.mini) }
            Spacer(minLength: 0)
            if !document.languageServers.isEmpty {
                Image(systemName: "bolt.fill").foregroundColor(NeoLinkTheme.accent).help("Code intelligence: \(document.languageServers)")
            }
            Button { session.action("diagnostics") } label: {
                Label("\(document.diagnosticCount)", systemImage: "exclamationmark.circle")
            }.help("Show diagnostics")
            Menu {
                Button("Go to Definition") { session.action("definition") }
                Button("Find References") { session.action("references") }
                Button("Show Documentation") { session.action("hover") }
                Button("Rename Symbol…") { session.action("rename") }
                Button("Code Actions…") { session.action("codeAction") }
                Button("Format Document") { session.action("format") }
                Divider()
                Button("Toggle Fold") { session.action("fold") }
                Button("Fold All") { session.action("foldAll") }
                Button("Unfold All") { session.action("unfoldAll") }
                Button("Toggle Inlay Hints") { session.action("inlayHints") }
                Divider()
                Text(document.languageServers.isEmpty ? "No language server for this file" : "Language server: \(document.languageServers)")
            } label: { Label("Code", systemImage: "curlybraces") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            TextSizeControl()
            Button { controller.runSelectedFile() } label: { Image(systemName: "play.fill") }
                .help("Save and run file in a terminal")
                .disabled(controller.selectedRunner == nil)
            Button { Task { await document.save() } } label: { Image(systemName: "square.and.arrow.down") }
                .accessibilityLabel("Save")
                .disabled(!document.isModified || document.isSaving)
                .help("Save file (⌘S)")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(NeoLinkTheme.textSecondary)
        .padding(.horizontal, 12).frame(height: 30)
        .background(NeoLinkTheme.editorBackground)
    }
}
