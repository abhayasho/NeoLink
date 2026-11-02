import SwiftUI

struct GitChangesView: View {
    let directory: URL
    let open: (URL) -> Void
    var prepareMutation: () async -> Bool = { true }
    var didMutate: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: GitChanges.Snapshot?
    @State private var selected: GitChange?
    @State private var selectedStash: String?
    @State private var staged = false
    @State private var patch = ""
    @State private var error: String?
    @State private var loading = false
    @State private var mutating = false
    @State private var revision = 0
    @State private var commitMessage = ""
    @State private var branchName = ""
    @State private var creatingBranch = false
    private var stagedCount: Int { snapshot?.changes.filter(\.staged).count ?? 0 }
    private var busy: Bool { loading || mutating }

    var body: some View {
        VStack(spacing: 0) {
            header
            NeoLinkTheme.horizontalSeparator()
            if let error { Text(error).font(.caption).foregroundStyle(NeoLinkTheme.warning).textSelection(.enabled).padding(10) }
            HSplitView {
                fileList.frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
                VStack(spacing: 0) {
                    diffControls
                    DiffPreview(text: patch)
                }.frame(minWidth: 380)
            }
            NeoLinkTheme.horizontalSeparator()
            HStack(alignment: .top, spacing: 12) {
                TextField("Commit message", text: $commitMessage, axis: .vertical)
                    .lineLimit(2...3).textFieldStyle(.roundedBorder).accessibilityLabel("Commit message")
                Button("Commit \(stagedCount) staged \(stagedCount == 1 ? "file" : "files")") {
                    mutate { root in try await GitChanges.commit(commitMessage, at: root); commitMessage = "" }
                }.disabled(busy || stagedCount == 0 || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(12)
            HStack {
                Text(mutating ? "Updating repository…" : "Commits use staged files and your Git identity. Save editor changes before Git operations.")
                Spacer()
                if busy { ProgressView().controlSize(.mini) }
            }.font(.system(size: 10)).foregroundStyle(NeoLinkTheme.textSecondary).padding([.horizontal, .bottom], 12)
        }
        .frame(width: 880, height: 640)
        .background(NeoLinkTheme.editorBackground).foregroundStyle(NeoLinkTheme.textPrimary)
        .alert("Create and switch branch", isPresented: $creatingBranch) {
            TextField("Branch name", text: $branchName)
            Button("Cancel", role: .cancel) {}
            Button("Create Branch") { mutate { root in try await GitChanges.switchBranch(branchName, create: true, at: root) } }
        } message: { Text("Creates a local branch from the current commit. Existing branches are never overwritten.") }
        .task(id: revision) { await reload() }
        .task(id: "\(selected?.id ?? "")-\(selectedStash ?? "")-\(staged)-\(revision)") { await loadDiff() }
    }

    private var header: some View {
        HStack {
            Label("Source Control", systemImage: "arrow.triangle.branch").font(.headline)
            Menu(snapshot?.branch ?? "Branch") {
                Button("Create Branch…") { branchName = ""; creatingBranch = true }
                Divider()
                ForEach(snapshot?.branches ?? [], id: \.self) { branch in
                    Button(branch) { mutate { root in try await GitChanges.switchBranch(branch, at: root) } }
                        .disabled(branch == snapshot?.branch)
                }
            }.disabled(busy || snapshot == nil).fixedSize().accessibilityLabel("Branches")
            Spacer()
            if !(snapshot?.stashes.isEmpty ?? true) {
                Menu("Stashes") {
                    Button("Working Tree") { selectedStash = nil }
                    ForEach(snapshot?.stashes ?? []) { stash in Button(stash.title) { selectedStash = stash.id } }
                }.fixedSize().disabled(busy)
            }
            Button { revision += 1 } label: { Image(systemName: "arrow.clockwise") }.help("Refresh changes").disabled(busy)
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(mutating)
        }.padding(14)
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(snapshot?.changes ?? []) { change in
                    Button {
                        selectedStash = nil; selected = change; staged = change.staged && !change.unstaged
                    } label: {
                        HStack {
                            Text(change.path).lineLimit(2).truncationMode(.middle)
                            Spacer()
                            Text("\(change.index)\(change.worktree)").font(.system(.caption, design: .monospaced))
                        }.font(.system(size: 12)).padding(8).contentShape(Rectangle())
                            .background(selectedStash == nil && selected?.id == change.id ? NeoLinkTheme.selection : .clear)
                    }.buttonStyle(.plain).disabled(mutating)
                }
                if snapshot?.changes.isEmpty == true { Text("Working tree clean").foregroundStyle(NeoLinkTheme.textSecondary).padding(12) }
            }
        }
    }

    private var diffControls: some View {
        HStack {
            if let stash = snapshot?.stashes.first(where: { $0.id == selectedStash }) {
                Text(stash.title).lineLimit(1)
                Spacer()
                Button("Working Tree") { selectedStash = nil }
            } else if let selected {
                Text(selected.path).lineLimit(1).truncationMode(.middle)
                Spacer()
                if selected.staged && selected.unstaged {
                    Picker("Changes", selection: $staged) { Text("Working tree").tag(false); Text("Staged").tag(true) }
                        .pickerStyle(.segmented).frame(width: 160)
                }
                if selected.unstaged { Button("Stage") { mutate { try await GitChanges.stage(selected, at: $0) } }.disabled(busy) }
                if selected.staged { Button("Unstage") { mutate { try await GitChanges.unstage(selected, at: $0) } }.disabled(busy) }
                Button("Open") {
                    guard let root = snapshot?.root else { return }
                    open(root.appendingPathComponent(selected.path)); dismiss()
                }.disabled(mutating || selected.index == "D" || selected.worktree == "D")
            } else { Text("Select a changed file") }
        }.font(.caption).padding(10)
    }

    private func mutate(_ operation: @escaping (URL) async throws -> Void) {
        guard !busy, let root = snapshot?.root else { return }
        mutating = true; error = nil
        Task {
            defer { mutating = false; revision += 1; didMutate() }
            guard await prepareMutation() else { error = "Save or close unsaved editor files before changing Git state."; return }
            do { try await operation(root) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            let result = try await GitChanges.snapshot(at: directory)
            guard !Task.isCancelled else { return }
            snapshot = result
            selected = result.changes.first(where: { $0.id == selected?.id }) ?? result.changes.first
            if !result.stashes.contains(where: { $0.id == selectedStash }) { selectedStash = nil }
            staged = selected.map { $0.staged && !$0.unstaged } ?? false
            // Status can change while the same file remains selected.
            await loadDiff()
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func loadDiff() async {
        patch = ""
        guard let root = snapshot?.root else { return }
        let fileID = selected?.id, stashID = selectedStash, wasStaged = staged
        do {
            let text: String
            if let stash = snapshot?.stashes.first(where: { $0.id == selectedStash }) { text = try await GitChanges.stashDiff(stash, at: root) }
            else if let selected { text = try await GitChanges.diff(selected, at: root, staged: staged) }
            else { return }
            guard !Task.isCancelled, selected?.id == fileID, selectedStash == stashID, staged == wasStaged else { return }
            patch = text.isEmpty ? "No textual changes in this view." : text
        } catch { if !Task.isCancelled { patch = error.localizedDescription } }
    }
}

private struct DiffPreview: NSViewRepresentable {
    let text: String
    @ObservedObject private var size = TextSizePreferences.shared
    final class Coordinator { var renderedText: String? }
    func makeCoordinator() -> Coordinator { Coordinator() }
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
        // The rendered view appends line separators. Cache the source instead of
        // rebuilding a potentially large diff whenever the commit message changes.
        if context.coordinator.renderedText != text {
            let result = NSMutableAttributedString(string: "")
            for line in text.components(separatedBy: "\n") {
                let color = line.hasPrefix("+") ? NeoLinkTheme.success : line.hasPrefix("-") ? NeoLinkTheme.error : line.hasPrefix("@@") ? NeoLinkTheme.warning : NeoLinkTheme.textPrimary
                result.append(NSAttributedString(string: line + "\n", attributes: [.foregroundColor: NSColor(color)]))
            }
            view.textStorage?.setAttributedString(result)
            context.coordinator.renderedText = text
        }
        if view.font?.pointSize != size.pointSize {
            view.font = .monospacedSystemFont(ofSize: size.pointSize, weight: .regular)
        }
    }
}
