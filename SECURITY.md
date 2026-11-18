# Security

## Supported versions

Security fixes go into the latest 2.x release. Versions 1.x (the Swift app) are no longer updated;
please upgrade.

## Reporting a vulnerability

Please report security problems privately through GitHub's
[private vulnerability reporting](https://github.com/abhayasho/NeoLink/security/advisories/new),
not in a public issue. Include what an attacker could do, the steps to reproduce it, and the NeoLink
version and operating system. You should hear back within a week.

## What NeoLink touches

Knowing this helps judge a report's impact:

- **Passwords.** Saved SSH passwords are stored in the macOS Keychain or the Windows Credential
  Manager, never in NeoLink's own files. NeoLink types a saved password only when the terminal shows a
  matching prompt, for a short time after you connect.
- **Files.** NeoLink reads and writes files in the projects you open. The built-in editor refuses to
  overwrite a file that changed on disk. Remote previews over SFTP are read-only.
- **Programs it starts.** Your shell, `ssh`, Neovim, Git, ripgrep, language servers and coding agents
  you choose, all with your own permissions. Coding agents act through their own permission prompts.
- **Network.** NeoLink makes no network connections on its own: no telemetry and no automatic
  update checks. **Help → Check for Updates** asks GitHub's API for the latest release (through the
  system's `curl`, over HTTPS) only when you choose it. SSH, agents and language servers connect
  where you point them. The installer downloads the release from
  GitHub and checks its SHA-256 and signature.
- **Crash reports** stay on your computer (`~/Library/Logs/NeoLink`, `%LOCALAPPDATA%\NeoLink\Logs`).
