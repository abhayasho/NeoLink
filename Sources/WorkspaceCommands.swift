import AppKit

extension Notification.Name {
    static let neoLinkNewTab = Notification.Name("NeoLink.newTab")
    static let neoLinkOpenFile = Notification.Name("NeoLink.openFile")
    static let neoLinkSaveFile = Notification.Name("NeoLink.saveFile")
    static let neoLinkOpenProject = Notification.Name("NeoLink.openProject")
    static let neoLinkCodeAction = Notification.Name("NeoLink.codeAction")
    static let neoLinkQuickOpen = Notification.Name("NeoLink.quickOpen")
    static let neoLinkFindInFiles = Notification.Name("NeoLink.findInFiles")
    static let neoLinkCloseTab = Notification.Name("NeoLink.closeTab")
    static let neoLinkNextTab = Notification.Name("NeoLink.nextTab")
    static let neoLinkPreviousTab = Notification.Name("NeoLink.previousTab")
    static let neoLinkToggleFiles = Notification.Name("NeoLink.toggleFiles")
    static let neoLinkToggleSidebar = Notification.Name("NeoLink.toggleSidebar")
    static let neoLinkNewSSHSession = Notification.Name("NeoLink.newSSHSession")
    static let neoLinkOpenAgent = Notification.Name("NeoLink.openAgent")
    static let neoLinkTextSize = Notification.Name("NeoLink.textSize")
    static let neoLinkToggleAgentPanel = Notification.Name("NeoLink.toggleAgentPanel")
    static let neoLinkShowGit = Notification.Name("NeoLink.showGit")
    static let neoLinkOpenREPL = Notification.Name("NeoLink.openREPL")
    static let neoLinkFileSaved = Notification.Name("NeoLink.fileSaved")
}

/// Native menus also provide standard text editing and terminal keyboard shortcuts.
@MainActor
final class WorkspaceCommands: NSObject, NSMenuItemValidation {
    func install() {
        let main = NSMenu()
        let appMenu = NSMenu(title: "NeoLink")
        add("About NeoLink", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), to: appMenu)
        appMenu.addItem(.separator())
        add("Hide NeoLink", action: #selector(NSApplication.hide(_:)), key: "h", to: appMenu)
        add("Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option], to: appMenu)
        add("Show All", action: #selector(NSApplication.unhideAllApplications(_:)), to: appMenu)
        appMenu.addItem(.separator())
        add("Quit NeoLink", action: #selector(NSApplication.terminate(_:)), key: "q", to: appMenu)
        attach(appMenu, to: main)

        let file = NSMenu(title: "File")
        command("New Local Tab", name: .neoLinkNewTab, key: "t", to: file)
        command("New SSH Connection…", name: .neoLinkNewSSHSession, key: "n", modifiers: [.command, .shift], to: file)
        command("Launch Coding Agent…", name: .neoLinkOpenAgent, key: "a", modifiers: [.command, .control], to: file)
        file.addItem(.separator())
        command("Open File…", name: .neoLinkOpenFile, key: "o", to: file)
        command("Open Project…", name: .neoLinkOpenProject, key: "o", modifiers: [.command, .shift], to: file)
        command("Save File", name: .neoLinkSaveFile, key: "s", to: file)
        command("Quick Open…", name: .neoLinkQuickOpen, key: "p", to: file)
        file.addItem(.separator())
        command("Close Tab", name: .neoLinkCloseTab, key: "w", to: file)
        add("Close Window", action: #selector(closeWindow(_:)), key: "w", modifiers: [.command, .shift], target: self, to: file)
        attach(file, to: main)

        let edit = NSMenu(title: "Edit")
        add("Undo", action: Selector(("undo:")), key: "z", to: edit)
        add("Redo", action: Selector(("redo:")), key: "z", modifiers: [.command, .shift], to: edit)
        edit.addItem(.separator())
        add("Cut", action: #selector(NSText.cut(_:)), key: "x", to: edit)
        add("Copy", action: #selector(NSText.copy(_:)), key: "c", to: edit)
        add("Paste", action: #selector(NSText.paste(_:)), key: "v", to: edit)
        add("Select All", action: #selector(selectAll(_:)), key: "a", target: self, to: edit)
        edit.addItem(.separator())
        let find = NSMenuItem(title: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        edit.addItem(find)
        command("Find in Files…", name: .neoLinkFindInFiles, key: "f", modifiers: [.command, .shift], to: edit)
        attach(edit, to: main)

        let code = NSMenu(title: "Code")
        for (title, action) in [("Go to Definition", "definition"), ("Find References", "references"), ("Show Documentation", "hover"), ("Rename Symbol…", "rename"), ("Code Actions…", "codeAction"), ("Format Document", "format"), ("Show Diagnostics", "diagnostics"), ("Toggle Fold", "fold"), ("Fold All", "foldAll"), ("Unfold All", "unfoldAll"), ("Toggle Inlay Hints", "inlayHints")] {
            let item = NSMenuItem(title: title, action: #selector(codeAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
            code.addItem(item)
        }
        code.addItem(.separator())
        let repl = NSMenu(title: "Open REPL")
        for (title, executable) in [("Python", "python3"), ("JavaScript", "node"), ("Swift", "swift"), ("Ruby", "irb"), ("Lua", "lua")] {
            let item = NSMenuItem(title: title, action: #selector(openREPL(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = executable
            repl.addItem(item)
        }
        attach(repl, to: code)
        attach(code, to: main)

        let view = NSMenu(title: "View")
        for (title, key, delta) in [("Increase Text Size", "+", 1), ("Decrease Text Size", "-", -1), ("Reset Text Size", "0", 0)] {
            let item = NSMenuItem(title: title, action: #selector(changeTextSize(_:)), keyEquivalent: key)
            item.target = self
            item.representedObject = delta
            view.addItem(item)
        }
        let equalZoom = NSMenuItem(title: "Increase Text Size", action: #selector(changeTextSize(_:)), keyEquivalent: "=")
        equalZoom.target = self; equalZoom.representedObject = 1
        equalZoom.isHidden = true; equalZoom.allowsKeyEquivalentWhenHidden = true
        view.addItem(equalZoom)
        view.addItem(.separator())
        add("Use GPU Text Rendering", action: #selector(toggleGPUTextRendering(_:)), target: self, to: view)
        add("Renderer Information…", action: #selector(showRendererInformation(_:)), target: self, to: view)
        view.addItem(.separator())
        command("Toggle Connections Sidebar", name: .neoLinkToggleSidebar, key: "s", modifiers: [.command, .control], to: view)
        command("Toggle File Browser", name: .neoLinkToggleFiles, key: "e", modifiers: [.command, .shift], to: view)
        command("Toggle Agent Panel", name: .neoLinkToggleAgentPanel, key: "b", modifiers: [.command, .control], to: view)
        command("Source Control…", name: .neoLinkShowGit, key: "g", modifiers: [.command, .shift], to: view)
        view.addItem(.separator())
        command("Next Tab", name: .neoLinkNextTab, key: "]", modifiers: [.command, .shift], to: view)
        command("Previous Tab", name: .neoLinkPreviousTab, key: "[", modifiers: [.command, .shift], to: view)
        view.addItem(.separator())
        add("Toggle Full Screen", action: #selector(toggleFullScreen(_:)), key: "f", modifiers: [.command, .control], target: self, to: view)
        attach(view, to: main)

        let window = NSMenu(title: "Window")
        add("Minimize", action: #selector(minimizeWindow(_:)), key: "m", target: self, to: window)
        add("Zoom", action: #selector(zoomWindow(_:)), target: self, to: window)
        window.addItem(.separator())
        add("Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), to: window)
        attach(window, to: main)
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }

    private func attach(_ menu: NSMenu, to parent: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        parent.addItem(item)
    }

    private func add(_ title: String, action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        menu.addItem(item)
    }

    private func command(_ title: String, name: Notification.Name, key: String, modifiers: NSEvent.ModifierFlags = [.command], to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: #selector(dispatchCommand(_:)), keyEquivalent: key)
        item.target = self
        item.representedObject = name.rawValue
        item.keyEquivalentModifierMask = modifiers
        menu.addItem(item)
    }

    @objc private func dispatchCommand(_ sender: NSMenuItem) {
        guard !isEditingSheet else { return }
        guard let name = sender.representedObject as? String else { return }
        NotificationCenter.default.post(name: Notification.Name(name), object: nil)
    }

    @objc private func codeAction(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: .neoLinkCodeAction, object: sender.representedObject)
    }

    @objc private func changeTextSize(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: .neoLinkTextSize, object: sender.representedObject)
    }
    @objc private func openREPL(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: .neoLinkOpenREPL, object: sender.representedObject)
    }

    @objc private func toggleGPUTextRendering(_ sender: NSMenuItem) {
        let preferences = TerminalRenderingPreferences.shared
        preferences.setUseGPU(!preferences.useGPU)
    }

    @objc private func showRendererInformation(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Text Rendering"
        alert.informativeText = activeTerminal?.rendering.summary ?? "Select a terminal or code editor to inspect its renderer."
        alert.addButton(withTitle: "OK")
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window) }
    }

    private var activeTerminal: InteractiveTerminalView? {
        var responder = NSApp.keyWindow?.firstResponder
        while let current = responder {
            if let terminal = current as? InteractiveTerminalView { return terminal }
            responder = current.nextResponder
        }
        return nil
    }

    @objc private func selectAll(_ sender: NSMenuItem) {
        if let editor = NSApp.keyWindow?.firstResponder as? CodeTerminalView { editor.selectCode(sender) }
        else { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: sender) }
    }

    // Keep menu and keyboard window actions available alongside the native buttons.
    @objc private func closeWindow(_ sender: NSMenuItem) { NSApp.keyWindow?.performClose(sender) }
    @objc private func minimizeWindow(_ sender: NSMenuItem) { NSApp.keyWindow?.miniaturize(sender) }
    @objc private func zoomWindow(_ sender: NSMenuItem) { NSApp.keyWindow?.zoom(sender) }
    @objc private func toggleFullScreen(_ sender: NSMenuItem) { NSApp.keyWindow?.toggleFullScreen(sender) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleGPUTextRendering(_:)) {
            menuItem.state = TerminalRenderingPreferences.shared.useGPU ? .on : .off
        }
        // Native dialog text fields still need Select All. Workspace shortcuts,
        // including Shift-Command-G, must defer to the file picker's commands.
        if menuItem.action == #selector(selectAll(_:)) { return true }
        return !isEditingSheet
    }

    private var isEditingSheet: Bool {
        NSApp.modalWindow != nil || NSApp.mainWindow?.attachedSheet != nil || NSApp.keyWindow?.sheetParent != nil
            || NSApp.windows.contains { $0 is NSSavePanel && $0.isVisible }
    }
}
