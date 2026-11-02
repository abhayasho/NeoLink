import Foundation

struct CodingAgent {
    let name: String
    let executable: String
    var arguments: [String] = []

    static func claude(continueSession: Bool = false) -> CodingAgent {
        CodingAgent(name: "Claude Code", executable: "claude", arguments: continueSession ? ["--continue"] : [])
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !executable.isEmpty && !executable.hasPrefix("-") &&
        !executable.contains(where: { $0.isNewline || $0 == "\0" }) &&
        !arguments.contains(where: { $0.contains("\0") })
    }

    func launchCommand(in directory: URL) -> String {
        let command = CommandRunner.executable(executable) ?? executable
        let invocation = ([command] + arguments).map(Self.quote).joined(separator: " ")
        let missing = "\(name) was not found. Install its CLI or choose its executable in the Agent launcher."
        return "cd -- \(Self.quote(directory.path)) && if command -v \(Self.quote(command)) >/dev/null 2>&1; then command \(invocation); else printf '%s\\n' \(Self.quote(missing)); fi\n"
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
