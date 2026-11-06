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
}
#endif
