import SwiftUI

struct ACPConversationView: View {
    @ObservedObject var session: ACPSession
    let contextURL: URL?
    let focusChanged: (Bool) -> Void
    @State private var includeFile = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(session.status).lineLimit(1)
                Spacer()
                if !session.modes.isEmpty {
                    Menu {
                        ForEach(session.modes) { mode in Button(mode.name) { session.setMode(mode.id) } }
                    } label: { Text(session.modes.first(where: { $0.id == session.currentMode })?.name ?? "Mode") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(session.isBusy)
                }
                Button { NotificationCenter.default.post(name: .neoLinkShowGit, object: session.directory) } label: { Image(systemName: "arrow.triangle.branch") }
                    .help("Review saved changes in Source Control")
            }.font(.system(size: 10)).foregroundStyle(NeoLinkTheme.textSecondary).padding(10)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if session.messages.isEmpty {
                            Text("Ask about your project or describe a change.")
                                .foregroundStyle(NeoLinkTheme.textSecondary).padding(.top, 16)
                        }
                        ForEach(session.messages) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(message.role).font(.system(size: 10, weight: .semibold)).foregroundStyle(NeoLinkTheme.textSecondary)
                                Text(message.text).font(.system(size: 12)).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading).id(message.id)
                        }
                        if !session.plan.isEmpty {
                            DisclosureGroup("Plan") {
                                ForEach(Array(session.plan.enumerated()), id: \.offset) { _, line in Text(line).font(.caption).textSelection(.enabled) }
                            }
                        }
                        ForEach(session.tools) { tool in
                            DisclosureGroup {
                                Text(tool.details).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(tool.title).lineLimit(2)
                                    Text(tool.status).font(.caption).foregroundStyle(NeoLinkTheme.textSecondary)
                                }
                            }.font(.system(size: 11))
                        }
                        if let error = session.error {
                            Text(error).font(.caption).foregroundStyle(NeoLinkTheme.warning).textSelection(.enabled)
                        }
                        if !session.isReady {
                            ForEach(session.authMethods) { method in
                                Button("Sign in · \(method.name)") { session.authenticate(method.id) }.disabled(session.isBusy)
                            }
                        }
                        if let permission = session.permissions.first {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Permission needed", systemImage: "hand.raised").font(.system(size: 11, weight: .semibold))
                                Text(permission.title).font(.system(size: 12))
                                ScrollView { Text(permission.details).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                                    .frame(height: 72)
                                ForEach(permission.options) { option in
                                    Button(option.name) { session.answer(permission, option: option.id) }
                                        .buttonStyle(.bordered).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                Button("Cancel request") { session.answer(permission, option: nil) }.buttonStyle(.plain).font(.caption)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(NeoLinkTheme.elevated, in: RoundedRectangle(cornerRadius: 6))
                        }
                        Color.clear.frame(height: 1).id("end")
                    }.padding(12)
                }
                .onChange(of: session.messages.count) { _ in proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: session.permissions.count) { _ in proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: session.isBusy) { _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            NeoLinkTheme.horizontalSeparator()
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $session.draft)
                    .focused($composerFocused)
                    .font(.system(size: 12)).scrollContentBackground(.hidden)
                    .frame(height: 64).accessibilityLabel("Agent prompt")
                if let contextURL {
                    Toggle("Include path: \(contextURL.lastPathComponent)", isOn: $includeFile)
                        .font(.system(size: 10)).help(contextURL.path)
                }
                HStack {
                    Text("ACP · \(session.directory.lastPathComponent)").font(.system(size: 10)).lineLimit(1)
                        .foregroundStyle(NeoLinkTheme.textSecondary).help(session.directory.path)
                    Spacer()
                    if session.isBusy {
                        Button("Stop") { session.cancel() }.disabled(!session.isReady)
                    } else {
                        Button("Send") {
                            let prompt = session.draft
                            session.send(prompt, contextPath: includeFile ? contextURL?.path : nil)
                            if session.isBusy { session.draft = "" }
                        }.disabled(!session.isReady || session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .keyboardShortcut(.return, modifiers: [.command])
                    }
                }.font(.system(size: 11))
            }.padding(10).background(NeoLinkTheme.elevated)
        }
        .onChange(of: composerFocused, perform: focusChanged)
        .onDisappear { focusChanged(false) }
    }
}
