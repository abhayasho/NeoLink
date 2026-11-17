//! Coding agents started from the launcher (the Swift app's `CodingAgent`).

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CodingAgent {
    pub name: String,
    pub executable: String,
    pub arguments: Vec<String>,
}

/// Quotes `value` for a POSIX shell.
pub fn quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

impl CodingAgent {
    pub fn claude(continue_session: bool) -> CodingAgent {
        CodingAgent { name: "Claude Code".into(), executable: "claude".into(), arguments: if continue_session { vec!["--continue".into()] } else { Vec::new() } }
    }

    /// The ACP adapter for Claude.
    pub fn claude_acp() -> CodingAgent {
        CodingAgent { name: "Claude".into(), executable: "claude-agent-acp".into(), arguments: Vec::new() }
    }

    pub fn is_valid(&self) -> bool {
        !self.name.trim().is_empty() && !self.executable.is_empty() && !self.executable.starts_with('-') && !self.executable.chars().any(|character| character == '\n' || character == '\r' || character == '\0') && !self.arguments.iter().any(|argument| argument.contains('\0'))
    }

    /// The line typed into a new shell: change to the project, run the agent if it exists, say so if not.
    /// `resolved` is the executable's full path when it was found in the usual places.
    pub fn launch_command(&self, directory: &str, resolved: Option<&str>) -> String {
        let command = resolved.unwrap_or(&self.executable);
        let invocation: Vec<String> = std::iter::once(command).chain(self.arguments.iter().map(String::as_str)).map(quote).collect();
        let missing = format!("{} was not found. Install its CLI or choose its executable in the Agent launcher.", self.name);
        format!("cd -- {} && if command -v {} >/dev/null 2>&1; then command {}; else printf '%s\\n' {}; fi\n", quote(directory), quote(command), invocation.join(" "), quote(&missing))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn launch_command_quotes_everything() {
        let agent = CodingAgent { name: "It's mine".into(), executable: "my agent".into(), arguments: vec!["--flag".into(), "a b".into()] };
        assert_eq!(
            agent.launch_command("/tmp/my project", None),
            "cd -- '/tmp/my project' && if command -v 'my agent' >/dev/null 2>&1; then command 'my agent' '--flag' 'a b'; else printf '%s\\n' 'It'\\''s mine was not found. Install its CLI or choose its executable in the Agent launcher.'; fi\n"
        );
        assert!(CodingAgent::claude(true).launch_command("/p", Some("/opt/bin/claude")).contains("command '/opt/bin/claude' '--continue'"));
    }

    #[test]
    fn invalid_agents_are_refused() {
        let agent = |name: &str, executable: &str| CodingAgent { name: name.into(), executable: executable.into(), arguments: Vec::new() };
        assert!(agent("A", "claude").is_valid());
        assert!(!agent(" ", "claude").is_valid());
        assert!(!agent("A", "").is_valid());
        assert!(!agent("A", "-rf").is_valid());
        assert!(!agent("A", "a\nb").is_valid());
    }
}
