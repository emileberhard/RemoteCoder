#if os(macOS)
import AppKit
import OSLog
import SwiftUI

@MainActor
final class TranscriptScrollHalt {
    enum Navigation: Equatable { case pageUp, pageDown, beginning, end }

    private(set) weak var scrollView: AppKitTranscriptContainer?
    private var isScrolling = false
    private weak var cursorRectsWindow: NSWindow?
    private static let logger = Logger(subsystem: "RemoteCoder", category: "Transcript")

    func attach(_ view: AppKitTranscriptContainer) {
        if scrollView !== view {
            let views: [NSView?] = [view, view.contentView, view.documentView]
            let described = views.map { view in
                view.map { "\(type(of: $0)) responsive=\(type(of: $0).isCompatibleWithResponsiveScrolling) layer=\($0.layer != nil)" } ?? "nil"
            }
            Self.logger.notice("transcript scroll view \(described.joined(separator: "; "), privacy: .public)")
        }
        scrollView = view
        updateCursorRects()
    }

    func detach(_ view: AppKitTranscriptContainer) {
        guard scrollView === view else { return }
        setScrollPhase(.idle)
        scrollView = nil
    }

    func setScrollPhase(_ phase: ScrollPhase) {
        guard !PerfBuild.isDisabled("scrollCursorGate") else { return }
        isScrolling = phase != .idle
        updateCursorRects()
    }

    private func updateCursorRects() {
        let target = isScrolling ? scrollView?.window : nil
        guard target !== cursorRectsWindow else { return }
        cursorRectsWindow?.enableCursorRects()
        cursorRectsWindow = nil
        guard let target, target.areCursorRectsEnabled else { return }
        target.disableCursorRects()
        cursorRectsWindow = target
    }

    static func forward(_ navigation: Navigation, from view: NSView) -> Bool {
        guard let window = view.window, let container = transcriptScrollView(in: window) as? AppKitTranscriptContainer else { return false }
        container.navigate(navigation)
        return true
    }

    static func transcriptScrollView(in window: NSWindow) -> NSScrollView? {
        window.contentView.flatMap(container(in:))
    }

    private static func container(in view: NSView) -> AppKitTranscriptContainer? {
        if let container = view as? AppKitTranscriptContainer { return container }
        for subview in view.subviews {
            if let container = container(in: subview) { return container }
        }
        return nil
    }

    func stop() { scrollView?.haltScrolling() }
}
#endif
