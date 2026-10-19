import XCTest
@testable import NeoLink

final class TerminalShellIntegrationTests: XCTestCase {
    func testTerminalEnvironmentPreservesAgentAndToolingWithUniqueTerminalDefaults() {
        let environment = TerminalEnvironment.values(
            inherited: ["PATH": "/custom/bin:/usr/bin", "SSH_AUTH_SOCK": "/tmp/test-agent.sock", "TERM": "dumb", "TERM_PROGRAM": "Other"],
            terminalDefaults: ["TERM=xterm-256color", "COLORTERM=truecolor"]
        )
        XCTAssertTrue(environment.contains("PATH=/custom/bin:/usr/bin"))
        XCTAssertTrue(environment.contains("SSH_AUTH_SOCK=/tmp/test-agent.sock"))
        XCTAssertTrue(environment.contains("TERM=xterm-256color"))
        XCTAssertTrue(environment.contains("TERM_PROGRAM=NeoLink"))
        XCTAssertEqual(environment.filter { $0.hasPrefix("TERM=") }.count, 1)
    }

    func testDefaultDotfilesKeepStartupOrderAndUnsetZDOTDIR() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        for (file, script) in [
            ".zshenv": "typeset -g NEOLINK_TEST_TRACE=env",
            ".zprofile": "NEOLINK_TEST_TRACE+=,profile",
            ".zshrc": "NEOLINK_TEST_TRACE+=,rc",
            ".zlogin": "NEOLINK_TEST_TRACE+=,login"
        ] {
            try script.write(to: fixture.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        let integration = try TerminalShellIntegration(originalDotDirectory: nil)
        let output = try runShell(integration, home: fixture, command: #"print -r -- "TRACE:$NEOLINK_TEST_TRACE UNSET:${+ZDOTDIR} HISTORY:$HISTFILE"; _neolink_report_cwd"#)
        XCTAssertTrue(output.contains("TRACE:env,profile,rc,login UNSET:0"), output)
        XCTAssertTrue(output.contains("HISTORY:\(fixture.path)/.zsh_history"), output)
        XCTAssertTrue(output.contains("\u{1B}]7;file://"), output)
    }

    func testCustomZDOTDIRChangesAreRespectedAndPathsAreEncoded() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        for name in ["original", "custom", "final", "directory with café"] {
            try FileManager.default.createDirectory(at: fixture.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let scripts = [
            "original/.zshenv": #"typeset -g NEOLINK_TEST_TRACE=env; ZDOTDIR="$HOME/custom""#,
            "custom/.zprofile": #"NEOLINK_TEST_TRACE+=,profile; ZDOTDIR="$HOME/final""#,
            "final/.zshrc": "NEOLINK_TEST_TRACE+=,rc",
            "final/.zlogin": "NEOLINK_TEST_TRACE+=,login"
        ]
        for (file, script) in scripts {
            try script.write(to: fixture.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        let integration = try TerminalShellIntegration(originalDotDirectory: fixture.appendingPathComponent("original").path)
        let output = try runShell(integration, home: fixture, command: #"print -r -- "TRACE:$NEOLINK_TEST_TRACE DOTDIR:$ZDOTDIR"; cd "$HOME/directory with café"; _neolink_report_cwd"#)
        XCTAssertTrue(output.contains("TRACE:env,profile,rc,login DOTDIR:\(fixture.path)/final"), output)
        XCTAssertTrue(output.contains("directory%20with%20caf"), output)
        XCTAssertTrue(output.removingPercentEncoding?.precomposedStringWithCanonicalMapping.contains("directory with café") == true, output)
    }

    func testTemporaryBootstrapIsRemovedWhenReleased() throws {
        var integration: TerminalShellIntegration? = try TerminalShellIntegration(originalDotDirectory: nil)
        let directory = try XCTUnwrap(integration?.directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".zshrc").path))
        integration = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testUserCanDisableFurtherStartupFiles() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try "unsetopt rcs".write(to: fixture.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        let integration = try TerminalShellIntegration(originalDotDirectory: nil)
        let output = try runShell(integration, home: fixture, command: #"print -r -- "UNSET:${+ZDOTDIR} HOOK:${+functions[_neolink_report_cwd]}""#)
        XCTAssertTrue(output.contains("UNSET:0 HOOK:0"), output)
    }

    private func makeFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NeoLink-shell-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func runShell(_ integration: TerminalShellIntegration, home: URL, command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-i", "-c", command]
        process.currentDirectoryURL = home
        process.environment = Dictionary(uniqueKeysWithValues: integration.environment(base: [
            "HOME=\(home.path)", "PATH=/usr/bin:/bin", "TERM=xterm-256color",
            "SHELL_SESSIONS_DISABLE=1", "LANG=en_US.UTF-8"
        ]).map {
            let parts = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(parts[0]), String(parts[1]))
        })
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: output, as: UTF8.self))
        return String(decoding: output, as: UTF8.self)
    }
}
