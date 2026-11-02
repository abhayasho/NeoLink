import SwiftUI

struct AgentLauncherView: View {
    @ObservedObject var controller: TabsController
    @State var directory: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var custom = false
    @State private var continueSession = false
    @AppStorage("customAgentName") private var customName = "My agent"
    @AppStorage("customAgentExecutable") private var customExecutable = ""
    @State private var arguments = ""
    @State private var error: String?

    private var agent: CodingAgent {
        if !custom { return .claude(continueSession: continueSession) }
        return CodingAgent(name: customName.trimmingCharacters(in: .whitespacesAndNewlines),
                           executable: customExecutable.trimmingCharacters(in: .whitespacesAndNewlines),
                           arguments: arguments.components(separatedBy: .newlines).filter { !$0.isEmpty })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Coding agent", systemImage: "sparkles").font(.system(size: 19, weight: .semibold))
            Text("Run an agent in its own project terminal.").foregroundStyle(NeoLinkTheme.textSecondary)
            Picker("Agent", selection: $custom) {
                Text("Claude Code").tag(false)
                Text("Custom CLI").tag(true)
            }.pickerStyle(.segmented)
            if custom {
                TextField("Agent name", text: $customName).accessibilityLabel("Agent name")
                TextField("Executable name or full path", text: $customExecutable).accessibilityLabel("Agent executable")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Arguments · one per line").font(.caption).foregroundStyle(NeoLinkTheme.textSecondary)
                    TextEditor(text: $arguments).font(.system(size: 12, design: .monospaced))
                        .frame(height: 70).accessibilityLabel("Agent arguments")
                    Text("Each line is passed literally. Arguments are not saved.").font(.caption).foregroundStyle(NeoLinkTheme.textSecondary)
                }
            } else {
                Toggle("Continue the last conversation in this project", isOn: $continueSession)
                if CommandRunner.executable("claude") == nil {
                    Text("Claude Code was not found in common install locations. Your shell’s PATH is also checked when you launch.")
                        .font(.caption).foregroundStyle(NeoLinkTheme.warning)
                }
                Link("Claude Code setup guide", destination: URL(string: "https://code.claude.com/docs/en/quickstart")!)
            }
            NeoLinkTheme.horizontalSeparator()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Project folder").font(.caption).foregroundStyle(NeoLinkTheme.textSecondary)
                    Text(directory?.path ?? "Choose a folder to work in")
                        .lineLimit(2).truncationMode(.middle).help(directory?.path ?? "")
                }
                Spacer()
                Button("Choose Folder…") {
                    WorkspaceAccess.shared.chooseFolder { directory = $0 }
                }
            }
            Text("Agents use files saved on disk. Save your edits before requesting changes. Sign in and approve actions in the agent’s terminal.")
                .font(.caption).foregroundStyle(NeoLinkTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(NeoLinkTheme.warning).font(.caption) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Launch in Tab") {
                    guard let directory else { return }
                    do {
                        try controller.openAgent(agent, in: directory)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .foregroundStyle(NeoLinkTheme.editorBackground)
                .disabled(directory == nil || !agent.isValid)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24).frame(width: 460)
        .background(NeoLinkTheme.sidebarBackground)
        .foregroundStyle(NeoLinkTheme.textPrimary)
        .tint(NeoLinkTheme.accent).preferredColorScheme(.dark)
    }
}
