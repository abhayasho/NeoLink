## NeoLink

NeoLink is a native macOS terminal app inspired by ones that I liked.
It combines tabbed local / SSH terminals with an integrated file browser so
you can work with local and remote files from a single window.

### Features

- **Tabbed terminals**: open multiple local and SSH sessions side‑by‑side.
- **Session sidebar**: quickly open a local tab or saved SSH session.
- **Directory‑aware terminal**: the current working directory is shown above the terminal.
- **Local file browser**:
  - Follows the active terminal tab.
  - Browse, create, rename, delete, and drag‑and‑drop files and folders.
- **Remote SFTP browser**:
  - When you SSH into a host, NeoLink detects the session and opens an SFTP view.
  - Browse remote directories, create / rename / delete entries.
  - Upload by dragging files from Finder into the SFTP pane.
  - Download individual files via the context menu.

### Requirements

- macOS 13 or later
- Xcode 15 or Swift toolchain 5.10 or later

> Note: the package targets Swift 5.10 on purpose to avoid Swift 6
> concurrency assertions in the current `swift-ssh-client` dependency.

### Building and running

**Option 1 – Run from terminal**

```bash
swift build
swift run
```

**Option 2 – Build a double‑clickable app (with icon)**

To get a `NeoLink.app` you can open from Finder or drag to Applications:

```bash
./scripts/build-app.sh
```

This builds a release binary, creates `NeoLink.app` in the project root, and embeds the app icon from `Resources/AppIcon.png`. You can then double‑click `NeoLink.app` or move it to `/Applications`.

### Using NeoLink

- **Local terminal**: use the “Local terminal” session in the sidebar or “New local tab”.
- **SSH**:
  - Either run `ssh user@host` in a local tab, or use the “SSH” button in the sidebar
    to create / edit saved SSH sessions.
  - When a remote SSH session is active, the file pane switches to **Remote files (SFTP)**.
  - Enter your password once in the SFTP pane; NeoLink stores it in the Keychain so
    future connections can auto‑reconnect without prompting.

### Roadmap ideas

- Two‑pane layout showing local and remote file browsers together.
- Server‑side copy / move for remote items.
- More advanced SSH session management (tunnels, jump hosts, etc.).
- Eventually this will be its one application, This is a very rough prototype. 

