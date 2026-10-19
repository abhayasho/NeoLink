import AppKit

extension Notification.Name {
    static let neoLinkNewTab = Notification.Name("NeoLink.newTab")
    static let neoLinkCloseTab = Notification.Name("NeoLink.closeTab")
    static let neoLinkNextTab = Notification.Name("NeoLink.nextTab")
    static let neoLinkPreviousTab = Notification.Name("NeoLink.previousTab")
    static let neoLinkToggleFiles = Notification.Name("NeoLink.toggleFiles")
    static let neoLinkToggleSidebar = Notification.Name("NeoLink.toggleSidebar")
    static let neoLinkNewSSHSession = Notification.Name("NeoLink.newSSHSession")
}

/// Native menus also provide standard text editing and terminal keyboard shortcuts.
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
        add("Select All", action: #selector(NSText.selectAll(_:)), key: "a", to: edit)
        attach(edit, to: main)

        let view = NSMenu(title: "View")
        command("Toggle Connections Sidebar", name: .neoLinkToggleSidebar, key: "s", modifiers: [.command, .control], to: view)
        command("Toggle File Browser", name: .neoLinkToggleFiles, key: "e", modifiers: [.command, .shift], to: view)
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

    // Keep menu and keyboard window actions available alongside the native buttons.
    @objc private func closeWindow(_ sender: NSMenuItem) { NSApp.keyWindow?.close() }
    @objc private func minimizeWindow(_ sender: NSMenuItem) { NSApp.keyWindow?.miniaturize(sender) }
    @objc private func zoomWindow(_ sender: NSMenuItem) { NSApp.keyWindow?.zoom(sender) }
    @objc private func toggleFullScreen(_ sender: NSMenuItem) { NSApp.keyWindow?.toggleFullScreen(sender) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { !isEditingSheet }

    private var isEditingSheet: Bool {
        NSApp.mainWindow?.attachedSheet != nil || NSApp.keyWindow?.sheetParent != nil
    }
}
