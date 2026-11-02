import XCTest
@testable import NeoLink

final class ACPTests: XCTestCase {
    func testFramingHandlesSplitUTF8AndMultipleMessages() throws {
        var framer = ACPLineFramer()
        let data = Data("{\"jsonrpc\":\"2.0\",\"method\":\"世界\"}\n{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}\n".utf8)
        var result: [[String: Any]] = []
        for byte in data { result += try framer.append(Data([byte])) }
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0]["method"] as? String, "世界")
        XCTAssertFalse(framer.hasPartialMessage)
        XCTAssertThrowsError(try framer.append(Data("not ACP\n".utf8)))
        var oversized = ACPLineFramer()
        XCTAssertThrowsError(try oversized.append(Data(repeating: 65, count: ACPLineFramer.limit + 1)))
    }

    @MainActor
    private func fixture() throws -> ACPSession {
        let python = try XCTUnwrap(CommandRunner.executable("python3"))
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/fixtures/acp-agent.py")
        return ACPSession(agent: CodingAgent(name: "Fixture", executable: python, arguments: [script.path]), directory: FileManager.default.temporaryDirectory)
    }
    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for ACP state")
    }

    @MainActor
    func testSessionStreamsTextRequestsPermissionAndPreservesToolUpdates() async throws {
        let session = try fixture(); defer { session.close() }
        session.connect()
        try await waitUntil { session.isReady && !session.isBusy }
        XCTAssertEqual(session.currentMode, "ask")
        session.setMode("plan")
        try await waitUntil { !session.isBusy }
        XCTAssertEqual(session.currentMode, "plan")
        session.send("review", contextPath: "/tmp/saved.py")
        try await waitUntil { !session.permissions.isEmpty }
        XCTAssertTrue(session.messages.contains { $0.text == "Hello 世界. " })
        XCTAssertTrue(session.messages.first?.text.contains("/tmp/saved.py") == true)
        let permission = try XCTUnwrap(session.permissions.first)
        XCTAssertEqual(permission.title, "Preview a change")
        XCTAssertTrue(permission.details.contains("example.py"))
        session.answer(permission, option: "forged-option")
        XCTAssertEqual(session.permissions.count, 1)
        session.answer(permission, option: "deny")
        try await waitUntil { !session.isBusy }
        XCTAssertTrue(session.messages.contains { $0.text == "Rejected." })
        XCTAssertEqual(session.tools.first?.status, "completed")
        XCTAssertTrue(session.tools.first?.details.contains("After:\nafter") == true)
        session.send("review")
        try await waitUntil { !session.permissions.isEmpty }
        session.answer(try XCTUnwrap(session.permissions.first), option: "allow")
        try await waitUntil { !session.isBusy }
        XCTAssertTrue(session.messages.contains { $0.text == "Approved." })
    }

    @MainActor
    func testCancelAnswersPendingPermissionsAndDisconnectEndsRequests() async throws {
        let session = try fixture(); defer { session.close() }
        session.connect(); try await waitUntil { session.isReady && !session.isBusy }
        session.send("cancel"); try await waitUntil { !session.permissions.isEmpty }
        session.cancel(); try await waitUntil { !session.isBusy }
        XCTAssertTrue(session.permissions.isEmpty)
        XCTAssertEqual(session.status, "Stopped")
        session.send("disconnect"); try await waitUntil { !session.isReady && !session.isBusy }
        XCTAssertNotNil(session.error)
    }

    @MainActor
    func testMalformedAgentOutputFailsWithoutHanging() async throws {
        let session = try fixture(); defer { session.close() }
        session.connect(); try await waitUntil { session.isReady && !session.isBusy }
        session.send("malformed"); try await waitUntil { !session.isReady && !session.isBusy }
        XCTAssertNotNil(session.error)
    }

    @MainActor
    func testMCPConfigurationIsExplicitAndValidated() throws {
        XCTAssertEqual(try ACPSession.parseMCP("").count, 0)
        let valid = "[{\"name\":\"files\",\"command\":\"/usr/bin/server\",\"args\":[\"--stdio\"],\"env\":[{\"name\":\"SCOPE\",\"value\":\"project\"}]}]"
        XCTAssertEqual(try ACPSession.parseMCP(valid).first?["name"] as? String, "files")
        XCTAssertThrowsError(try ACPSession.parseMCP("[{\"name\":\"x\",\"command\":\"relative\",\"args\":[]}]"))
        XCTAssertThrowsError(try ACPSession.parseMCP("{}"))
        XCTAssertThrowsError(try ACPSession.parseMCP("[{\"name\":\"x\",\"command\":\"/bin/server\",\"args\":[],\"env\":{\"KEY\":\"value\"}}]"))
    }

    @MainActor
    func testTimeoutClosesTransportAndResumesEveryPendingRequest() async throws {
        let session = try fixture()
        let transport = ACPTransport(); defer { transport.close() }
        try transport.start(session.agent, directory: session.directory)
        _ = try await transport.request("initialize", ["protocolVersion":1, "clientCapabilities":["terminal":false,"fs":["writeTextFile":false]]])
        let other = Task { try await transport.request("never", [:], timeout: 5) }
        do {
            _ = try await transport.request("never", [:], timeout: 0.05)
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("in time")) }
        do { _ = try await other.value; XCTFail("Expected other request to end") }
        catch { XCTAssertFalse(transport.isRunning) }
    }

    @MainActor
    func testClosingOneParallelSessionLeavesTheOtherUsable() async throws {
        let first = try fixture(), second = try fixture()
        defer { first.close(); second.close() }
        first.connect(); second.connect()
        try await waitUntil { first.isReady && second.isReady && !first.isBusy && !second.isBusy }
        first.send("cancel"); second.send("review")
        try await waitUntil { !first.permissions.isEmpty && !second.permissions.isEmpty }
        first.close()
        XCTAssertTrue(first.permissions.isEmpty)
        second.answer(try XCTUnwrap(second.permissions.first), option: "deny")
        try await waitUntil { !second.isBusy }
        XCTAssertTrue(second.isReady)
        XCTAssertTrue(second.messages.contains { $0.text == "Rejected." })
    }
}
