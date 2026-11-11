import AppKit
import Metal
import XCTest
@testable import NeoLink

final class TerminalRenderingTests: XCTestCase {
    @MainActor
    func testGPUPreferenceDefaultsOnAndPersistsExplicitChoice() throws {
        let suite = "NeoLinkRenderingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = TerminalRenderingPreferences(defaults: defaults)
        XCTAssertTrue(preferences.useGPU)
        XCTAssertFalse(preferences.continuousRefresh, "an idle workspace presents nothing unless the user asks for repeats")
        preferences.setContinuousRefresh(true)
        XCTAssertTrue(TerminalRenderingPreferences(defaults: defaults).continuousRefresh)
        preferences.setContinuousRefresh(false)
        XCTAssertFalse(TerminalRenderingPreferences(defaults: defaults).continuousRefresh)
        preferences.setUseGPU(false)
        XCTAssertFalse(TerminalRenderingPreferences(defaults: defaults).useGPU)
        preferences.setUseGPU(true)
        XCTAssertTrue(TerminalRenderingPreferences(defaults: defaults).useGPU)
    }

    @MainActor
    func testRendererWaitsForWindowAndSwitchesWithoutLosingTerminalContents() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        _ = NSApplication.shared
        // XCTest's host is a separate bundle. Mirror the installed app's resource
        // layout so SwiftTerm can resolve shaders without a developer-only path.
        let host = Bundle(for: Self.self)
        let source = host.bundleURL.deletingLastPathComponent().appendingPathComponent("SwiftTerm_SwiftTerm.bundle")
        let resources = try XCTUnwrap(host.resourceURL)
        let shaders = resources.appendingPathComponent("SwiftTerm_SwiftTerm.bundle")
        let createdShaders = !FileManager.default.fileExists(atPath: shaders.path)
        if createdShaders {
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: shaders)
        }
        defer { if createdShaders { try? FileManager.default.removeItem(at: shaders) } }
        let suite = "NeoLinkRendererSwitchTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = TerminalRenderingPreferences(defaults: defaults)
        let view = InteractiveTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        let rendering = TerminalRendering(view: view, preferences: preferences)
        rendering.attachToWindow()
        XCTAssertFalse(view.isUsingMetalRenderer)
        view.feed(text: "\u{1b}[31mCOLOR_MARKER\u{1b}[0m\r\nUnicode: 界 👋\r\n")
        let before = view.terminal.getBufferAsData(kind: .normal)
        let columns = view.terminal.cols
        let rows = view.terminal.rows

        let window = NSWindow(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        rendering.attachToWindow()
        XCTAssertNil(rendering.failure)
        XCTAssertTrue(view.isUsingMetalRenderer)
        XCTAssertTrue(rendering.summary.contains("Metal (GPU)"))

        preferences.setUseGPU(false)
        XCTAssertFalse(view.isUsingMetalRenderer)
        XCTAssertEqual(view.terminal.getBufferAsData(kind: .normal), before)
        preferences.setUseGPU(true)
        XCTAssertTrue(view.isUsingMetalRenderer)
        XCTAssertEqual(view.terminal.getBufferAsData(kind: .normal), before)
        XCTAssertEqual(view.terminal.cols, columns)
        XCTAssertEqual(view.terminal.rows, rows)
        view.removeFromSuperview()
        view.feed(text: "DETACHED_OUTPUT")
        XCTAssertTrue(String(decoding: view.terminal.getBufferAsData(kind: .normal), as: UTF8.self).contains("DETACHED_OUTPUT"))
    }
}
