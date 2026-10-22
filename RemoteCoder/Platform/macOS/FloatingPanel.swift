#if os(macOS)
import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    private let host: NSView
    private let becameKey: @MainActor () -> Void
    private let dismissRequested: @MainActor () -> Void

    init<Content: View>(content: Content, becameKey: @escaping @MainActor () -> Void,
                        dismiss: @escaping @MainActor () -> Void) {
        host = NSHostingView(rootView: content)
        self.becameKey = becameKey
        dismissRequested = dismiss
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
        contentView = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func becomeKey() {
        super.becomeKey()
        becameKey()
    }

    override func resignKey() {
        super.resignKey()
        dismissRequested()
    }

    override func cancelOperation(_ sender: Any?) {
        dismissRequested()
    }

    func present(in frame: (NSSize) -> NSRect) {
        host.layoutSubtreeIfNeeded()
        setFrame(frame(host.fittingSize), display: false)
        makeKeyAndOrderFront(nil)
    }
}
#endif
