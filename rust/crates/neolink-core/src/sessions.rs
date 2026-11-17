//! Saved SSH connections (the Swift app's `Session` and `SSHSessionInput`).

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Connection {
    pub id: String,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub username: String,
}

/// Hostnames, SSH aliases and IPv6 addresses are accepted; command options and whitespace never are.
pub fn is_valid(host: &str, username: &str, port: &str) -> bool {
    let acceptable = |value: &str| !value.is_empty() && !value.starts_with('-') && !value.contains('@') && !value.chars().any(|character| character.is_whitespace() || character.is_control());
    acceptable(host.trim()) && acceptable(username.trim()) && port.parse::<u32>().is_ok_and(|port| (1..=65535).contains(&port))
}

impl Connection {
    /// The arguments of the system's `ssh` for this connection. The fields were checked by
    /// [`is_valid`], and `--` ends the options in any case.
    pub fn ssh_arguments(&self) -> Vec<String> {
        vec!["-p".into(), self.port.to_string(), "-l".into(), self.username.clone(), "--".into(), self.host.clone()]
    }

    /// `user@host`, as the sidebar shows it.
    pub fn address(&self) -> String {
        format!("{}@{}", self.username, self.host)
    }

    /// Whether `search` (any case) is in the name, host or user.
    pub fn matches(&self, search: &str) -> bool {
        let needle = search.to_lowercase();
        needle.is_empty() || [&self.name, &self.host, &self.username].iter().any(|field| field.to_lowercase().contains(&needle))
    }
}

/// A new identity in the form the Swift app writes (an upper-case UUID), from the clock and a counter:
/// unique within one user's list, which is all it has to be.
pub fn new_id(seed: u64) -> String {
    let mut state = seed ^ 0x9E37_79B9_7F4A_7C15;
    let mut next = || {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        state
    };
    let (a, b) = (next(), next());
    format!("{:08X}-{:04X}-4{:03X}-{:04X}-{:012X}", (a >> 32) as u32, (a >> 16) as u16, a as u16 & 0x0FFF, (b >> 48) as u16 & 0x3FFF | 0x8000, b & 0xFFFF_FFFF_FFFF)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn options_and_whitespace_are_never_hosts() {
        assert!(is_valid("server.example.com", "me", "22"));
        assert!(is_valid("fe80::1", "me", "2222"));
        assert!(!is_valid("-oProxyCommand=evil", "me", "22"));
        assert!(!is_valid("host name", "me", "22"));
        assert!(!is_valid("me@host", "me", "22"));
        assert!(!is_valid("host", "-l", "22"));
        assert!(!is_valid("host", "", "22"));
        assert!(!is_valid("host", "me", "0"));
        assert!(!is_valid("host", "me", "70000"));
        assert!(!is_valid("host", "me", "port"));
    }

    #[test]
    fn the_ssh_command_ends_its_options_before_the_host() {
        let connection = Connection { id: new_id(1), name: "Box".into(), host: "example.com".into(), port: 2222, username: "me".into() };
        assert_eq!(connection.ssh_arguments(), ["-p", "2222", "-l", "me", "--", "example.com"]);
        assert_eq!(connection.address(), "me@example.com");
        assert!(connection.matches("EXAMPLE") && connection.matches("box") && !connection.matches("other"));
        let id = new_id(42);
        assert_eq!(id.len(), 36);
        assert_ne!(id, new_id(43));
    }
}
