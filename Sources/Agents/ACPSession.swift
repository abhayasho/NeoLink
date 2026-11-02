import Foundation

struct ACPMessage: Identifiable {
    let id: UUID
    let role: String
    var text: String
    init(role: String, text: String) { id = UUID(); self.role = role; self.text = text }
}
struct ACPChoice: Identifiable { let id: String; let name: String }
struct ACPPermission: Identifiable {
    let id = UUID()
    let requestID: Any
    let title: String
    let details: String
    let options: [ACPChoice]
}
struct ACPTool: Identifiable {
    let id: String
    var title: String
    var status: String
    var details: String
}

/// One process and conversation per session; hiding the panel does not stop it.
@MainActor
final class ACPSession: ObservableObject, Identifiable {
    let id = UUID()
    let agent: CodingAgent
    let directory: URL
    @Published private(set) var messages: [ACPMessage] = []
    @Published private(set) var tools: [ACPTool] = []
    @Published private(set) var permissions: [ACPPermission] = []
    @Published private(set) var plan: [String] = []
    @Published private(set) var modes: [ACPChoice] = []
    @Published private(set) var currentMode = ""
    @Published private(set) var authMethods: [ACPChoice] = []
    @Published private(set) var status = "Connecting…"
    @Published private(set) var isBusy = false
    @Published private(set) var isReady = false
    @Published private(set) var error: String?
    @Published var draft = ""
    var onTurnFinished: (() -> Void)?
    private var transport: ACPTransport?
    private var sessionID: String?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var responseID: UUID?
    private var messageID: String?
    private var receivedCharacters = 0
    private var cancelling = false
    private var closed = false
    private let mcpServers: [[String: Any]]

    init(agent: CodingAgent, directory: URL, mcpServers: [[String: Any]] = []) {
        self.agent = agent; self.directory = directory; self.mcpServers = mcpServers
    }

    static func parseMCP(_ text: String) throws -> [[String: Any]] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard text.utf8.count <= 64 * 1024,
              let entries = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]], entries.count <= 16 else {
            throw ACPFailure(message: "MCP configuration must be an array of up to 16 stdio servers.")
        }
        var names = Set<String>()
        return try entries.map { entry in
            guard let name = entry["name"] as? String, !name.isEmpty, names.insert(name).inserted,
                  let command = entry["command"] as? String, command.hasPrefix("/"), !command.contains("\0"),
                  let args = entry["args"] as? [String], !args.contains(where: { $0.contains("\0") }) else {
                throw ACPFailure(message: "Each MCP server needs a unique name, an absolute command path, and an args array.")
            }
            guard entry["env"] == nil || entry["env"] is [[String: String]] else {
                throw ACPFailure(message: "MCP env must be an array of name and value entries.")
            }
            let env = entry["env"] as? [[String: String]] ?? []
            guard env.allSatisfy({ value in
                guard let key = value["name"], let content = value["value"] else { return false }
                return !key.isEmpty && !key.contains("=") && !key.contains("\0") && !content.contains("\0")
            }) else { throw ACPFailure(message: "MCP environment entries require valid name and value strings.") }
            return ["name":name, "command":command, "args":args, "env":env]
        }
    }

    func connect() {
        guard transport == nil, !closed else { return }
        let channel = ACPTransport()
        transport = channel
        channel.onMessage = { [weak self] in self?.receive($0) }
        channel.onDisconnect = { [weak self] message in
            guard let self, !self.closed else { return }
            self.isReady = false; self.isBusy = false; self.permissions = []
            self.status = "Disconnected"; self.error = message
        }
        do { try channel.start(agent, directory: directory) }
        catch { self.error = error.localizedDescription; status = "Could not connect"; return }
        isBusy = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false }
            do {
                let result = try await channel.request("initialize", ["protocolVersion":1,
                    "clientInfo":["name":"neolink", "title":"NeoLink", "version":"1.5.0"],
                    "clientCapabilities":["fs":["readTextFile":false,"writeTextFile":false],"terminal":false]])
                guard result["protocolVersion"] as? Int == 1 else { throw ACPFailure(message: "The adapter requires an unsupported ACP version.") }
                // Only advertise and offer authentication flows this client can perform.
                self.authMethods = (result["authMethods"] as? [[String: Any]] ?? []).compactMap {
                    guard ($0["type"] as? String ?? "agent") == "agent", let id = $0["id"] as? String else { return nil }
                    return ACPChoice(id: id, name: $0["name"] as? String ?? id)
                }
                try await self.newSession()
            } catch {
                if !self.closed { self.error = error.localizedDescription; self.status = "Connection needs attention" }
            }
        }
    }

    private func newSession() async throws {
        guard let transport else { return }
        let result = try await transport.request("session/new", ["cwd":directory.path,"mcpServers":mcpServers], timeout: 60)
        guard !closed, let id = result["sessionId"] as? String, !id.isEmpty else { throw ACPFailure(message: "Agent did not provide a session ID.") }
        sessionID = id
        if let state = result["modes"] as? [String: Any] {
            currentMode = state["currentModeId"] as? String ?? ""
            modes = (state["availableModes"] as? [[String: Any]] ?? []).compactMap {
                guard let id = $0["id"] as? String else { return nil }
                return ACPChoice(id: id, name: $0["name"] as? String ?? id)
            }
        }
        isReady = true; status = "Ready"; error = nil
    }

    func authenticate(_ method: String) {
        guard !isBusy, !isReady, authMethods.contains(where: { $0.id == method }), let transport else { return }
        isBusy = true; error = nil; status = "Signing in…"
        task = Task {
            defer { isBusy = false }
            do {
                _ = try await transport.request("authenticate", ["methodId":method], timeout: 300)
                try await newSession()
            } catch { if !closed { self.error = error.localizedDescription; status = "Sign-in failed" } }
        }
    }

    func send(_ text: String, contextPath: String? = nil) {
        guard isReady, !isBusy, let sessionID, let transport else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 128 * 1024 else { error = "Enter a prompt smaller than 128 KB."; return }
        var content = text
        if let contextPath { content += "\n\nContext file (saved on disk): " + contextPath }
        appendMessage(role: "You", text: content)
        responseID = nil; messageID = nil; receivedCharacters = 0
        tools = []; plan = []; error = nil; isBusy = true; cancelling = false; status = "Working…"
        let turn = UUID(); generation = turn
        task = Task {
            defer {
                if generation == turn { isBusy = false; cancelling = false; cancelPermissions(); onTurnFinished?() }
            }
            do {
                let result = try await transport.request("session/prompt", ["sessionId":sessionID,"prompt":[["type":"text","text":content]]], timeout: 1800)
                if !closed, generation == turn { status = result["stopReason"] as? String == "cancelled" ? "Stopped" : "Ready" }
            } catch {
                if !closed {
                    self.error = error.localizedDescription
                    status = cancelling ? "Stopped · reconnect to continue" : "Turn failed"
                }
            }
        }
    }

    func setMode(_ mode: String) {
        guard !isBusy, isReady, let sessionID, let transport, modes.contains(where: { $0.id == mode }) else { return }
        isBusy = true
        task = Task {
            defer { isBusy = false }
            do { _ = try await transport.request("session/set_mode", ["sessionId":sessionID,"modeId":mode]); currentMode = mode }
            catch { self.error = error.localizedDescription }
        }
    }

    func cancel() {
        guard isBusy, !cancelling, let sessionID else { return }
        cancelling = true; status = "Stopping…"
        cancelPermissions()
        transport?.notify("session/cancel", ["sessionId":sessionID])
        let turn = generation
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, self.generation == turn, self.cancelling, self.isBusy else { return }
            self.transport?.close(); self.isReady = false; self.status = "Stopped · reconnect to continue"
        }
    }

    func answer(_ permission: ACPPermission, option: String?) {
        guard let index = permissions.firstIndex(where: { $0.id == permission.id }) else { return }
        guard option == nil || permission.options.contains(where: { $0.id == option }) else { return }
        permissions.remove(at: index)
        let outcome: [String: Any] = option.map { ["outcome":"selected","optionId":$0] } ?? ["outcome":"cancelled"]
        transport?.reply(id: permission.requestID, result: ["outcome":outcome])
        if isBusy && !cancelling { status = permissions.isEmpty ? "Working…" : "Permission needed" }
    }
    private func cancelPermissions() { for permission in permissions { answer(permission, option: nil) } }

    func close() {
        closed = true; generation = UUID(); cancelPermissions(); transport?.close(); transport = nil
        task?.cancel(); task = nil; isReady = false; isBusy = false; status = "Closed"
    }

    private func appendMessage(role: String, text: String) {
        messages.append(ACPMessage(role: role, text: String(text.prefix(128 * 1024))))
        while messages.count > 200 || messages.reduce(0, { $0 + $1.text.utf8.count }) > 2 * 1024 * 1024 { messages.removeFirst() }
    }

    private func receive(_ message: [String: Any]) {
        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        if let requestID = message["id"] {
            guard method == "session/request_permission", params["sessionId"] as? String == sessionID else {
                transport?.reject(id: requestID); return
            }
            guard isBusy, !cancelling, permissions.count < 16 else {
                transport?.reply(id: requestID, result: ["outcome":["outcome":"cancelled"]]); return
            }
            let tool = params["toolCall"] as? [String: Any] ?? [:]
            let previous = tools.first { $0.id == tool["toolCallId"] as? String }
            var optionIDs = Set<String>()
            let options = (params["options"] as? [[String: Any]] ?? []).prefix(16).compactMap { option -> ACPChoice? in
                guard let id = option["optionId"] as? String, optionIDs.insert(id).inserted,
                      let name = option["name"] as? String, name.count <= 1024 else { return nil }
                return ACPChoice(id: id, name: name)
            }
            let hasDetails = tool["content"] != nil || tool["rawInput"] != nil || tool["rawOutput"] != nil
            permissions.append(ACPPermission(requestID: requestID,
                                             title: Self.bounded(tool["title"] as? String ?? previous?.title ?? "Agent requests permission", limit: 1024),
                                             details: hasDetails ? Self.details(tool) : previous?.details ?? Self.details(tool), options: options))
            status = "Permission needed"
            return
        }
        guard method == "session/update", params["sessionId"] as? String == sessionID,
              let update = params["update"] as? [String: Any], let kind = update["sessionUpdate"] as? String else { return }
        switch kind {
        case "agent_message_chunk":
            guard let content = update["content"] as? [String: Any], content["type"] as? String == "text", let text = content["text"] as? String else { return }
            receivedCharacters += text.utf8.count
            if receivedCharacters > 512 * 1024 { error = "This response exceeded the display limit. The turn was stopped."; cancel(); return }
            let nextMessage = update["messageId"] as? String
            if responseID == nil || (nextMessage != nil && messageID != nextMessage) {
                appendMessage(role: agent.name, text: ""); responseID = messages.last?.id
            }
            messageID = nextMessage
            if let index = messages.firstIndex(where: { $0.id == responseID }) { messages[index].text += text }
        case "tool_call", "tool_call_update":
            guard let id = update["toolCallId"] as? String else { return }
            responseID = nil
            if let index = tools.firstIndex(where: { $0.id == id }) {
                if let title = update["title"] as? String { tools[index].title = Self.bounded(title, limit: 1024) }
                if let status = update["status"] as? String { tools[index].status = Self.bounded(status, limit: 128) }
                if update["content"] != nil || update["rawInput"] != nil || update["rawOutput"] != nil { tools[index].details = Self.details(update) }
            } else {
                tools.append(ACPTool(id: id, title: Self.bounded(update["title"] as? String ?? "Tool", limit: 1024), status: Self.bounded(update["status"] as? String ?? "pending", limit: 128), details: Self.details(update)))
                if tools.count > 200 { tools.removeFirst() }
            }
        case "plan":
            plan = (update["entries"] as? [[String: Any]] ?? []).prefix(100).map { Self.bounded("\($0["status"] as? String ?? "pending") · \($0["content"] as? String ?? "")", limit: 2048) }
        case "current_mode_update": currentMode = update["currentModeId"] as? String ?? currentMode
        default: break
        }
    }

    private static func details(_ value: [String: Any]) -> String {
        var details: [String] = []
        if let input = value["rawInput"], JSONSerialization.isValidJSONObject(input),
           let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]) {
            details.append(String(decoding: data, as: UTF8.self))
        }
        for content in value["content"] as? [[String: Any]] ?? [] {
            if content["type"] as? String == "diff" {
                details.append("\(content["path"] as? String ?? "File")\nBefore:\n\(content["oldText"] as? String ?? "")\nAfter:\n\(content["newText"] as? String ?? "")")
            } else if let block = content["content"] as? [String: Any], let text = block["text"] as? String { details.append(text) }
        }
        if details.isEmpty, let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            details.append(String(decoding: data, as: UTF8.self))
        }
        return bounded(details.joined(separator: "\n"), limit: 16 * 1024)
    }

    private static func bounded(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n[Preview truncated]" : text
    }
}
