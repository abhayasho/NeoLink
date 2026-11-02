# Coding agents in NeoLink

NeoLink 1.5 supports native ACP conversations and ordinary agent terminals. Both use a project folder you choose. Save editor changes before asking an agent to modify files.

## Native conversation

1. Install an ACP adapter. For Claude, follow the official [`claude-agent-acp` setup](https://github.com/agentclientprotocol/claude-agent-acp), including its authentication requirements. NeoLink does not bundle or install it.
2. Open **Agent** (`Control-Command-A`), choose **Native conversation (ACP)**, and select **Claude Code**. This starts `claude-agent-acp`, not `claude`.
3. For another ACP adapter, choose **Custom CLI**, provide its executable name/full path and any arguments, one per line. Common Homebrew, `~/.local/bin`, `~/.npm-global/bin`, and inherited PATH locations are searched; a full path works for other installations.
4. Choose the project and connect. Enter a prompt, then click **Send** or press `Command-Return`. Use **Include path** to explicitly attach the active file's saved path. Unsaved text and selections are not transmitted.
5. Read tool previews and choose an offered permission option or **Cancel request**. **Stop** cancels the turn. The mode menu reflects modes advertised by the adapter.

The panel displays streamed text, plans, tool status and text/diff previews. Its branch button opens Git review for that session's project. Saved file changes refresh after a turn; dirty editor buffers are retained. Native prompts are text-only: images, audio and rich embedded resources are not supported yet.

Use **+** to create another independent session and the session picker to switch among them. Hiding the panel preserves sessions. **×** closes the selected session and stops its adapter; `Command-W` does the same while its prompt has focus. Quitting closes all native sessions. Conversation restoration after relaunch is not implemented.

## Terminal interface

Choose **Terminal** for a regular `claude` executable or another CLI. Claude's **Continue the last conversation** uses `claude --continue`. Authentication, model selection and action approvals appear in the terminal. The terminal can live in the right panel or a workspace tab. See [Claude Code setup](https://code.claude.com/docs/en/quickstart).

Custom names and executable paths are remembered. Arguments are passed literally and are not saved. Shell pipelines, substitutions and redirections are not interpreted as arguments.

## MCP configuration

Native mode optionally accepts a JSON array under **MCP servers**. The adapter receives these entries in `session/new` and manages the servers itself. Commands must be absolute executable paths. For example, replace the sample command with your installed server:

```json
[
  {
    "name": "project-context",
    "command": "/absolute/path/to/mcp-server",
    "args": ["--stdio"],
    "env": [{"name": "PROJECT_ROOT", "value": "/absolute/path/to/project"}]
  }
]
```

Configuration is optional, limited to 16 stdio servers and 64 KiB, and is not persisted. HTTP/SSE MCP transports are not advertised. The adapter may also provide its own MCP settings. NeoLink is not a standalone MCP client, and does not supply a model router, API-key store, direct Ollama client, or edit-prediction service. These remain separate future integrations.

## Protocol and validation

The native client implements [ACP v1 stdio](https://agentclientprotocol.com/protocol/v1/transports): initialization, new sessions, text prompts, streamed updates, tool permissions, cancellation, advertised session modes and agent-managed authentication. Optional client filesystem and terminal capabilities are explicitly disabled. Use an adapter with its own file/tool execution; adapters that require editor-managed filesystem/terminal RPC are not supported. Newer configuration-option APIs, session loading and rich-resource rendering are not yet implemented.

Adapters run as local processes with your account's access. The UI displays permission requests that an adapter sends; it does not sandbox the adapter or independently authorize every operating-system operation. Authentication and provider settings belong to the adapter. macOS privacy prompts remain governed by the app signing identity described in the [workspace guide](CODING_WORKSPACE.md).

The automated suite uses an offline protocol fixture, with no credentials, network calls or file-changing agent tools. It checks fragmented UTF-8, streaming, tool updates, explicit permission choices, cancellation, disconnects, malformed output, timeouts, and independent parallel sessions. The published Claude adapter 0.99.1 also accepted NeoLink’s initialization handshake at protocol version 1; no live prompt was sent. Live provider/model behavior still needs validation with the chosen adapter and account. No claim of compatibility with every ACP implementation is made.
