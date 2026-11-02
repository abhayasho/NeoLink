import XCTest
@testable import NeoLink

final class CodingAgentTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NeoLinkAgent-\(UUID().uuidString) 'quoted' $(literal)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.resolvingSymlinksInPath()
    }

    func testLaunchUsesProjectAndLiteralArguments() async throws {
        let root = try directory()
        let executable = root.appendingPathComponent("fake 'agent'")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$PWD\"\nprintf '<%s>\\n' \"$@\"\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let arguments = ["a b", "quote'", "$(touch injected)", "; echo injected", "--help", "line\nnext"]
        let agent = CodingAgent(name: "Fake agent", executable: executable.path, arguments: arguments)
        let result = try await CommandRunner.run("/bin/zsh", ["-f", "-c", agent.launchCommand(in: root)])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), root.path + "\n" + arguments.map { "<\($0)>\n" }.joined())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("injected").path))
    }

    func testMissingExecutableExplainsSetupWithoutExecutingAnything() async throws {
        let root = try directory()
        let agent = CodingAgent(name: "Missing agent", executable: "/does-not-exist/neolink-agent")
        let result = try await CommandRunner.run("/bin/zsh", ["-f", "-c", agent.launchCommand(in: root)])
        XCTAssertTrue(String(decoding: result.output, as: UTF8.self).contains("Missing agent was not found"))
    }

    @MainActor
    func testAgentGetsIndependentProjectTabAndRefreshesFilesOnLeaving() throws {
        let root = try directory()
        let controller = TabsController(useNeovim: false)
        let local = try XCTUnwrap(controller.selectedTerminalTab)
        try controller.openAgent(.claude(continueSession: true), in: root, docked: false)
        let agent = try XCTUnwrap(controller.selectedTerminalTab)
        XCTAssertNotEqual(agent.id, local.id)
        XCTAssertEqual(agent.agentName, "Claude Code")
        XCTAssertEqual(agent.state.currentDirectory, root.path)
        XCTAssertTrue(agent.configuration.startupCommand?.contains("'--continue'") == true)
        XCTAssertNil(agent.state.pendingCommand)
        XCTAssertFalse(agent.state.hasStarted)
        XCTAssertNil(local.state.pendingCommand)
        controller.selectedTabID = local.id
        XCTAssertEqual(controller.fileRefreshRevision, 1)
        XCTAssertTrue(controller.tabs.contains { $0.id == agent.id })
    }

    @MainActor
    func testMissingProjectAndInvalidCommandDoNotCreateTabs() throws {
        let controller = TabsController(useNeovim: false)
        let root = try directory()
        XCTAssertThrowsError(try controller.openAgent(.claude(), in: root.appendingPathComponent("missing")))
        XCTAssertThrowsError(try controller.openAgent(CodingAgent(name: "Bad", executable: "a\nb"), in: root))
        XCTAssertThrowsError(try controller.openAgent(CodingAgent(name: "Bad", executable: "--bad"), in: root))
        XCTAssertEqual(controller.tabs.count, 1)
        XCTAssertNil(CommandRunner.executable(root.path), "A directory is not a CLI executable")
    }
}
