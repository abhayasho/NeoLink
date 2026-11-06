//
//  NeoLinkExternalGridView.swift
//
//  NeoLink addition: the `feed` bracket for a host that mutates the terminal grid directly.
//

#if os(macOS)
import AppKit

extension TerminalView {
    /// Runs `body` (which mutates the terminal through the `externalGrid*` API) inside the same
    /// preparation/finish bracket as `feed`, so display updates, selection invalidation and the
    /// host's frame scheduling follow the normal output path.
    public func externalGridUpdate(_ body: (Terminal) -> Void) {
        feedPrepare()
        body(terminal)
        feedFinish()
    }

    /// Call inside `externalGridUpdate`. Installs `lines` as the visible rows (see
    /// `Terminal.externalGridExchangeRows`) and keeps their cached geometry valid: they moved, they did not change.
    public func externalGridExchange(_ lines: [BufferLine]) -> [BufferLine]? {
        guard let displaced = terminal.externalGridExchangeRows(lines) else { return nil }
        #if canImport(MetalKit)
        for line in lines { metalMovedLines.insert(ObjectIdentifier(line)) }
        discardRetainedScrollLines()
        #endif
        return displaced
    }
}
#endif
