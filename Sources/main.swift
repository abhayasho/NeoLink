import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private let tabsController = TabsController()
    private var approvedWindowClose = false
    private let commands = WorkspaceCommands()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        commands.install()
        let contentView = ContentView(tabsController: tabsController)
        let hosting = NSHostingController(rootView: contentView)
        if #available(macOS 13.3, *) {
            hosting.safeAreaRegions = []
        }

        let initialSize = NSSize(width: 1280, height: 800)
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: screenFrame.midX - initialSize.width / 2,
            y: screenFrame.midY - initialSize.height / 2
        )

        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NeoLink"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = NSColor(NeoLinkTheme.sidebarBackground)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.appearance = NSAppearance(named: .darkAqua)
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 900, height: 560)
        window.setFrameAutosaveName("NeoLinkMainWindow")
        window.contentViewController = hosting
        window.delegate = self
        window.makeKeyAndOrderFront(nil)

        self.window = window

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) { tabsController.shutdownAgents(); tabsController.codeSession.shutdown() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if approvedWindowClose { return true }
        tabsController.approveClosingAll { [weak self, weak sender] approved in
            guard approved, let self, let sender else { return }
            self.approvedWindowClose = true
            sender.performClose(nil)
        }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if approvedWindowClose { return .terminateNow }
        tabsController.approveClosingAll { sender.reply(toApplicationShouldTerminate: $0) }
        return .terminateLater
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

