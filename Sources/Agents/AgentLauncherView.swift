import SwiftUI

struct AgentLauncherView: View {
    @ObservedObject var controller: TabsController
    @State var directory: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var acp = false
    @State private var mcpJSON = ""
    @State private var custom = false
    @State private var continueSession = false
    @State private var docked = true
    @AppStorage("customAgentName") private var customName = "My agent"
    @AppStorage("customAgentExecutable") private var customExecutable = ""
    @State private var arguments = ""
    @State private var error: String?

    private var agent: CodingAgent {
        if !custom { return acp ? CodingAgent(name: "Claude", executable: "claude-agent-acp") : .claude(continueSession: continueSession) }
        return CodingAgent(name: customName.trimmingCharacters(in: .whitespacesAndNewlines),
                           executable: customExecutable.trimmingCharacters(in: .whitespacesAndNewlines),
                           arguments: arguments.components(separatedBy: .newlines).filter { !$0.isEmpty })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Coding agent", systemImage: "sparkles").font(.system(size: 19, weight: .semibold))
            Picker("Interface", selection: $acp) {
                Text("Terminal").tag(false)
                Text("Native conversation (ACP)").tag(true)
            }.pickerStyle(.segmented)
            Text(acp ? "Connect an installed ACP adapter. The agent manages models and authentication." : "Run an agent in its own project terminal.").font(.caption).foregroundStyle(NeoLinkTheme.textSecondary)
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
                if !acp { Toggle("Continue the last conversation in this project", isOn: $continueSession) }
                if acp {
                    Text("Requires the claude-agent-acp adapter. A regular claude executable belongs in Terminal mode.").font(.caption).foregroundStyle(NeoLinkTheme.textSecondary)
                    Link("ACP adapter setup", destination: URL(string: "https://github.com/agentclientprotocol/claude-agent-acp")!)
                } else if CommandRunner.executable("claude") == nil {
                    Text("Claude Code was not found in common install locations. Your shell’s PATH is also checked when you launch.")
                        .font(.caption).foregroundStyle(NeoLinkTheme.warning)
                }
                Link("Claude Code setup guide", destination: URL(string: "https://code.claude.com/docs/en/quickstart")!)
            }
            NeoLinkTheme.horizontalSeparator()
            if !acp { Toggle("Open alongside the editor", isOn: $docked) }
            if acp {
                DisclosureGroup("MCP servers · optional") {
                    Text("JSON array of stdio servers: name, absolute command, args, env. Sent to this agent when connecting; not saved.").font(.caption).foregroundStyle(NeoLinkTheme.textSecondary)
                    TextEditor(text: $mcpJSON).font(.system(size: 10, design: .monospaced)).frame(height: 70).accessibilityLabel("MCP servers JSON")
                }.font(.caption)
            }
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
            Text(acp ? "The adapter runs with your account’s access. Save edits before requesting changes. Tool permissions appear in the conversation; authentication and provider settings belong to the adapter." : "Agents use files saved on disk. Save your edits before requesting changes. Sign in and approve actions in the agent’s terminal.")
                .font(.caption).foregroundStyle(NeoLinkTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(NeoLinkTheme.warning).font(.caption) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(acp ? "Connect Agent" : (docked ? "Launch in Panel" : "Launch in Tab")) {
                    guard let directory else { return }
                    do {
                        if acp { try controller.openACP(agent, in: directory, mcpServers: ACPSession.parseMCP(mcpJSON)) }
                        else { try controller.openAgent(agent, in: directory, docked: docked) }
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
