import SwiftUI

struct GitChangesView: View {
    let directory: URL
    let open: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: GitChanges.Snapshot?
    @State private var selected: GitChange?
    @State private var staged = false
    @State private var patch = ""
    @State private var error: String?
    @State private var loading = false
    @State private var revision = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Source Control", systemImage: "arrow.triangle.branch").font(.headline)
                Text(snapshot?.branch ?? "").foregroundStyle(NeoLinkTheme.textSecondary)
                Spacer()
                Button { revision += 1 } label: { Image(systemName: "arrow.clockwise") }.help("Refresh changes")
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(14)
            NeoLinkTheme.horizontalSeparator()
            if let error { Text(error).font(.caption).foregroundStyle(NeoLinkTheme.warning).textSelection(.enabled).padding(10) }
            HSplitView {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(snapshot?.changes ?? []) { change in
                            Button {
                                selected = change; staged = change.staged && !change.unstaged
                            } label: {
                                HStack {
                                    Text(change.path).lineLimit(2).truncationMode(.middle)
                                    Spacer()
                                    Text("\(change.index)\(change.worktree)").font(.system(.caption, design: .monospaced))
                                }.font(.system(size: 12)).padding(8).contentShape(Rectangle())
                                    .background(selected?.id == change.id ? NeoLinkTheme.selection : .clear)
                            }.buttonStyle(.plain)
                        }
                        if snapshot?.changes.isEmpty == true { Text("Working tree clean").foregroundStyle(NeoLinkTheme.textSecondary).padding(12) }
                    }
                }.frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
                VStack(spacing: 0) {
                    HStack {
                        if let selected {
                            Text(selected.path).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if selected.staged && selected.unstaged {
                                Picker("Changes", selection: $staged) { Text("Working tree").tag(false); Text("Staged").tag(true) }
                                    .pickerStyle(.segmented).frame(width: 170)
                            }
                            Button("Open File") {
                                guard let root = snapshot?.root else { return }
                                open(root.appendingPathComponent(selected.path)); dismiss()
                            }.disabled(selected.index == "D" || selected.worktree == "D")
                        } else { Text("Select a changed file") }
                    }.font(.caption).padding(10)
                    DiffPreview(text: patch)
                }.frame(minWidth: 380)
            }
            HStack { Text("Read-only diff review · use Git in a terminal to stage, commit or switch branches"); Spacer(); if loading { ProgressView().controlSize(.mini) } }
                .font(.system(size: 10)).foregroundStyle(NeoLinkTheme.textSecondary).padding(10)
        }
        .frame(width: 880, height: 580)
        .background(NeoLinkTheme.editorBackground).foregroundStyle(NeoLinkTheme.textPrimary)
        .task(id: revision) {
            loading = true; error = nil
            defer { loading = false }
            do {
                let result = try await GitChanges.snapshot(at: directory)
                guard !Task.isCancelled else { return }
                snapshot = result
                selected = result.changes.first(where: { $0.id == selected?.id }) ?? result.changes.first
                staged = selected.map { $0.staged && !$0.unstaged } ?? false
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .task(id: "\(selected?.id ?? "")-\(staged)-\(revision)") {
            patch = ""
            guard let selected, let root = snapshot?.root else { return }
            do {
                let text = try await GitChanges.diff(selected, at: root, staged: staged)
                guard !Task.isCancelled else { return }
                patch = text.isEmpty ? "No textual changes in this view." : text
            } catch { if !Task.isCancelled { patch = error.localizedDescription } }
        }
    }
}

private struct DiffPreview: NSViewRepresentable {
    let text: String
    @ObservedObject private var size = TextSizePreferences.shared
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let view = NSTextView()
        view.isEditable = false; view.isRichText = false
        view.isHorizontallyResizable = true; view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.backgroundColor = NSColor(NeoLinkTheme.editorBackground)
        view.textContainerInset = NSSize(width: 10, height: 10)
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text {
            let result = NSMutableAttributedString(string: "")
            for line in text.components(separatedBy: "\n") {
                let color = line.hasPrefix("+") ? NeoLinkTheme.success : line.hasPrefix("-") ? NeoLinkTheme.error : line.hasPrefix("@@") ? NeoLinkTheme.warning : NeoLinkTheme.textPrimary
                result.append(NSAttributedString(string: line + "\n", attributes: [.foregroundColor: NSColor(color)]))
            }
            view.textStorage?.setAttributedString(result)
        }
        view.font = .monospacedSystemFont(ofSize: size.pointSize, weight: .regular)
    }
}
