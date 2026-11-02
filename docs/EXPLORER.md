# Explorer

The local explorer defaults to a project tree. Click a folder to expand it without replacing its parent list; click a file to open its existing or new workspace tab. Drag the divider to widen the explorer. The options menu switches to the original Folder List, which retains all name/date/size sorts. Follow Terminal still follows each local shell's current directory; choosing a project or manually browsing pauses following until resumed.

## Orientation and actions

- Expanded single-child folder chains compact into one path such as `src/main/java`. Turn **Compact Folders** off to show every level. Collapse All keeps the browser root intact.
- **Reveal Active File** opens the ancestors of a file within the current root and scrolls to its selected row as editor tabs change. Active dotfiles can appear even when other hidden files are suppressed. Files outside the root do not silently replace it; the context-menu Reveal action can navigate to an outside file's parent explicitly.
- Language abbreviations and document/configuration symbols distinguish source files, shell scripts, JSON/YAML/TOML, Dockerfiles, editor settings, Markdown, PDFs, images, and archives.
- Error/warning counters come from open Neovim buffers and aggregate on folders. They do not imply a project-wide lint pass or language server for remote files.
- Right-click to create a file/folder in a directory, copy an absolute or project-relative path, open an integrated terminal in the containing folder, use the default app, show in Finder, copy/paste, rename, or move to Trash. Folder rows accept dropped local files; background drops target the root. Copies never replace an existing destination.
- The tree filter searches currently loaded/expanded branches. **⌘P** searches the project's bounded file list with fuzzy subsequence matching and ranking; **⇧⌘F** searches file contents. Symbol search is not part of Quick Open.

## Git and refreshing

Git status supplies semantic colors and letter badges: green A/U for added/untracked, blue M for modified, red D for deleted or ! for conflicts, and muted orange R for renamed. Deleted paths remain as struck-through placeholders; their context action opens Source Control rather than trying to edit a missing file. Folder badges summarize changes beneath them.

Ignored entries are dimmed by default and can be hidden in explorer options. The implementation uses Git's own ignore evaluation, including nested ignore files, negations, and global excludes; already tracked files retain their tracked status. A bounded `git status --porcelain=v1 -z --ignored=matching --untracked-files=normal` query avoids expanding ignored/untracked directory contents merely to decorate the tree. Git decorations can be absent if Git is unavailable, the directory is not a repository, or the bounded query cannot finish.

The tree refreshes after local file operations, app/editor saves, agent refresh events, shell directory/prompt reports, app activation, and immediate-child changes under the root. Refresh is debounced. Use the refresh button for changes made by other processes while NeoLink remains active. There is one nonrecursive root event source, not a recursive watcher of every workspace file; externally edited nested files are not continuously monitored.

## Resource bounds and SSH/SFTP

Directory reads run on a background actor, with at most two pending loads per tree. Collapsed sibling subtrees are not traversed. Expanded compact chains inspect at most 16 levels per request, do not automatically follow symlinks, and stop at dependency/build folders. The view shows at most 5,000 rows, caches at most roughly 128 directory listings, and retains at most 10,000 entries per directory. The footer indicates a limit; use Quick Open or browse a smaller root when needed.

The SSH/SFTP pane retains its endpoint display, connection reuse, Keychain authentication, connect/disconnect controls, directory navigation, remote creation/rename/delete, drag uploads, downloads, and read-only file previews. Local Git decoration does not launch remote Git commands, add remote watchers, or fetch a remote repository. The native source-control panel remains available separately.

Git output and ignore behavior are based on the official [git-status](https://git-scm.com/docs/git-status) documentation.

## Validation

Version 1.7 passed 80 native tests and the Neovim runtime regression checks. Explorer tests cover lazy loads, compaction, reveal, hidden active files, diagnostics aggregation, rapid root changes, symlink cycles, fuzzy matching, ignore rules/negations, tracked files matching ignore patterns, and deleted placeholders. Existing local-copy, per-terminal browser, SSH-input, and remote-browser regressions remain covered. Installed-app checks verified tree expansion, Git decorations, fuzzy Quick Open with automatic reveal, terminal folder routing, and switching between Tree and Folder List. Live authenticated SFTP transfer testing still requires a reachable server.
