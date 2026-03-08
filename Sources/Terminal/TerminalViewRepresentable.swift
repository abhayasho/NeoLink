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

final class TerminalState: ObservableObject, @unchecked Sendable {
    @Published var currentDirectory: String?
    /// When set, the terminal view will send this string to the shell (e.g. "cd /path\n") then clear it.
    @Published var pendingCommand: String?
    /// Terminal window title (e.g. "user@host" when SSH sets it); used to show remote files without re-entering host/user.
    @Published var terminalTitle: String?
}

struct TerminalViewRepresentable: NSViewRepresentable {
    let configuration: TerminalConfiguration
    @ObservedObject var state: TerminalState

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let state: TerminalState

        init(state: TerminalState) {
            self.state = state
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            let state = self.state
            DispatchQueue.main.async {
                state.terminalTitle = title.isEmpty ? nil : title
            }
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            let state = self.state
            DispatchQueue.main.async {
                state.currentDirectory = directory
            }
        }

        func processTerminated(source: TerminalView, exitCode: Int32?) {}
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        // Match terminal colors to the app theme (avoid the “black gap”).
        view.nativeBackgroundColor = NSColor(red: 0x1e / 255, green: 0x1e / 255, blue: 0x1e / 255, alpha: 1)
        view.nativeForegroundColor = NSColor(red: 0xd4 / 255, green: 0xd4 / 255, blue: 0xd4 / 255, alpha: 1)
        view.caretColor = NSColor(white: 0.9, alpha: 1)
        startProcess(for: configuration, in: view)
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        guard let cmd = state.pendingCommand, !cmd.isEmpty else { return }
        let bytes = ArraySlice(cmd.utf8)
        nsView.process?.send(data: bytes)
        state.pendingCommand = nil
    }

    private func startProcess(for configuration: TerminalConfiguration, in view: LocalProcessTerminalView) {
        switch configuration.backend {
        case .localShell:
            view.startProcess(executable: "/bin/zsh", args: ["-l"], environment: nil)
        case .ssh(let host, let username, let port):
            var args: [String] = []
            if port != 22 {
                args.append(contentsOf: ["-p", String(port)])
            }
            args.append("\(username)@\(host)")
            view.startProcess(executable: "/usr/bin/ssh", args: args, environment: nil)
        }
    }
}


