#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class WindowTabbing {
    private struct PendingTab {
        let value: ConversationWindowValue
        weak var host: NSWindow?
    }

    private var pending: PendingTab?

    func openTab(_ value: ConversationWindowValue, using openWindow: OpenWindowAction) {
        pending = NSApp.keyWindow.map { PendingTab(value: value, host: $0) }
        openWindow(value: value)
    }

    fileprivate func adopt(_ window: NSWindow, opening value: ConversationWindowValue?) {
        guard let pending, pending.value == value else { return }
        self.pending = nil
        guard let host = pending.host, host !== window, host.tabbedWindows?.contains(window) != true else { return }
        host.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }
}

struct WindowTabAdoption: NSViewRepresentable {
    let tabbing: WindowTabbing
    let value: ConversationWindowValue?

    func makeNSView(context: Context) -> AdoptingView {
        AdoptingView(tabbing: tabbing, value: value)
    }

    func updateNSView(_ view: AdoptingView, context: Context) {}

    final class AdoptingView: NSView {
        private let tabbing: WindowTabbing
        private let value: ConversationWindowValue?

        init(tabbing: WindowTabbing, value: ConversationWindowValue?) {
            self.tabbing = tabbing
            self.value = value
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            tabbing.adopt(window, opening: value)
        }
    }
}

struct WindowTabCommands: Commands {
    let tabbing: WindowTabbing
    @FocusedValue(\.chatWindowActions) private var actions
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") { tabbing.openTab(.newChat(slot: UUID()), using: openWindow) }
                .keyboardShortcut("t")
                .disabled(actions == nil)
        }
    }
}
#endif
