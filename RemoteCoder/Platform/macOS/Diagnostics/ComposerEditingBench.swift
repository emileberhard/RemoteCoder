#if RC_PERF_HARNESS
import AppKit
import SwiftUI

@MainActor
enum ComposerEditingBench {
    static func run(window: NSWindow) async throws {
        let owners = try await releaseGraph(window: window)
        try await assertRelease(owners)
        PerfBuild.gauge("composer.editing.passed", 1)
    }

    private static func releaseGraph(window: NSWindow) async throws -> WeakOwnership {
        guard let root = window.contentView else { throw Failure("composer fixture window has no content") }
        let id = UUID()
        let document = ComposerDocument(content: .init(runs: [.text("before "), .paste(.init(id: id, text: "paste")), .text(" after")]), onChange: {})
        let hosting = NSHostingView(rootView: AnyView(Fixture(document: document).environment(AppThemeStore())))
        let width = min(600, root.bounds.width)
        let height = min(240, root.bounds.height)
        hosting.frame = NSRect(x: root.bounds.midX - width / 2, y: root.bounds.midY - height / 2, width: width, height: height)
        let originalResponder = window.firstResponder
        root.addSubview(hosting)
        defer {
            autoreleasepool {
                window.makeFirstResponder(nil)
                hosting.rootView = AnyView(EmptyView())
                hosting.layoutSubtreeIfNeeded()
                hosting.removeFromSuperview()
                if let originalResponder, originalResponder.acceptsFirstResponder {
                    window.makeFirstResponder(originalResponder)
                }
            }
        }
        return try await prepare(hosting: hosting, window: window, document: document, id: id)
    }

    private static func prepare(hosting: NSView, window: NSWindow, document: ComposerDocument, id: UUID) async throws -> WeakOwnership {
        let view = try await editor(in: hosting)
        guard window.makeFirstResponder(view) else { throw Failure("composer fixture cannot take focus") }
        try await check(view, document: document, id: id)
        guard let reference = Mirror(reflecting: view).children.first(where: { $0.label == "composer" }),
              let coordinator = Mirror(reflecting: reference.value).children.first?.value as AnyObject? else {
            throw Failure("composer coordinator is missing")
        }
        let undoTarget = NSObject()
        document.undoManager.registerUndo(withTarget: undoTarget) { _ in }
        return WeakOwnership(document: document, coordinator: coordinator, undoTarget: undoTarget)
    }

    private static func check(_ view: NSTextView, document: ComposerDocument, id: UUID) async throws {
        document.edit(.updatePaste(id, "edited paste"))
        view.undoManager?.undo()
        guard document.content.pasted.first?.text == "paste" else { throw Failure("paste editor undo did not restore content") }
        view.undoManager?.redo()
        guard document.content.pasted.first == .init(id: id, text: "edited paste") else { throw Failure("paste editor redo lost identity") }
        view.setSelectedRange(NSRange(location: 8, length: 0))
        view.deleteBackward(nil)
        guard document.content.pasted.isEmpty else { throw Failure("delete did not remove the whole chip") }
        view.undoManager?.undo()
        guard document.content.pasted.first == .init(id: id, text: "edited paste") else { throw Failure("delete undo lost paste content or identity") }
        view.setSelectedRange(NSRange(location: 8, length: 6))
        view.deleteBackward(nil)
        guard document.content.expandedText == "before edited paste" else { throw Failure("tail delete did not remove the selected text") }
        guard view.selectedRange() == NSRange(location: 8, length: 0) else { throw Failure("tail delete left a stale selection") }
        view.undoManager?.undo()
        guard document.content.expandedText == "before edited paste after" else { throw Failure("tail delete undo did not restore the text") }
        view.setSelectedRange(NSRange(location: 8, length: 0))
        view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        document.edit(.dictation("dictated"))
        guard document.isComposing, !document.content.expandedText.contains("dictated") else { throw Failure("dictation changed marked text") }
        view.unmarkText()
        try await Task.sleep(for: .milliseconds(30))
        guard !document.isComposing, document.content.expandedText == "before edited pasteにほん dictated after",
              document.content.pasted.first?.id == id else { throw Failure("marked-text commit reordered dictation or paste") }
        view.undoManager?.undo()
        guard !document.content.expandedText.contains("dictated"), document.content.pasted.first?.id == id else {
            throw Failure("dictation undo changed the inline paste")
        }
    }

    private static func assertRelease(_ owners: WeakOwnership) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if owners.isReleased { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        guard owners.isReleased else {
            throw Failure("unmounted composer retained its document, coordinator or undo target")
        }
    }

    private final class WeakOwnership {
        weak var document: ComposerDocument?
        weak var coordinator: AnyObject?
        weak var undoTarget: NSObject?
        init(document: ComposerDocument, coordinator: AnyObject, undoTarget: NSObject) {
            self.document = document
            self.coordinator = coordinator
            self.undoTarget = undoTarget
        }
        var isReleased: Bool { document == nil && coordinator == nil && undoTarget == nil }
    }

    private static func editor(in root: NSView) async throws -> NSTextView {
        for _ in 0..<30 {
            root.layoutSubtreeIfNeeded()
            if let view = findEditor(in: root) { return view }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw Failure("composer fixture did not mount")
    }

    private static func findEditor(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, text.isEditable, text.accessibilityIdentifier() == "codex-composer-input" { return text }
        for child in view.subviews { if let text = findEditor(in: child) { return text } }
        return nil
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private struct Fixture: View {
        let document: ComposerDocument
        @FocusState private var focus: Bool
        var body: some View {
            ComposerTextInput(document: document, prompt: "Message", focus: $focus,
                actions: ComposerInputActions(send: {}, lastSentPrompt: { nil }, stop: { false }, attach: { _ in },
                    openPastedText: { _ in }, dropTargetChanged: { _ in }), maximumLines: 6).padding()
        }
    }
}
#endif
