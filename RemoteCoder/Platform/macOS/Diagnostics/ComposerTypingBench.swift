#if RC_PERF_HARNESS
import AppKit
import Foundation

@MainActor
enum ComposerTypingBench {
    static func run(screen: ChatScreenModel, window: NSWindow) async throws {
        for size in [1_000, 10_000] {
            screen.composerAttachments = []
            screen.input = String(String(repeating: "A representative draft paragraph with ordinary words.\n", count: 200).prefix(size))
            try await Task.sleep(for: .milliseconds(150))
            guard let root = window.contentView, let view = findEditor(in: root), window.makeFirstResponder(view) else {
                throw Failure("native composer is not mounted or cannot take focus")
            }
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
            for index in 1...3 {
                let paste = ComposerPaste<PastedImage>(fileURLs: [], images: [],
                    string: "Dictation \(index)\n" + String(repeating: "pasted words ", count: 150))
                guard screen.attachPastedContent(paste) else { throw Failure("paste was not attached") }
            }
            try await Task.sleep(for: .milliseconds(250))
            let initialLength = view.string.utf16.count
            view.setSelectedRange(NSRange(location: initialLength, length: 0))
            var durations: [UInt64] = []
            durations.reserveCapacity(80)
            for _ in 0..<80 {
                guard NSApp.isActive, window.isKeyWindow, window.firstResponder === view else {
                    throw Failure("composer lost active ownership during typing")
                }
                let start = PerfBuild.uptimeNanoseconds()
                let span = PerfBuild.span("composer.insert")
                view.insertText("x", replacementRange: view.selectedRange())
                root.layoutSubtreeIfNeeded()
                span.end()
                durations.append(PerfBuild.uptimeNanoseconds() - start)
                try await Task.sleep(for: .milliseconds(16))
            }
            guard view.string.utf16.count == initialLength + 80 else { throw Failure("typing lost draft characters") }
            let sorted = durations.sorted()
            PerfBuild.gauge("composer.\(size).keys", durations.count)
            PerfBuild.gauge("composer.\(size).p50.us", Int(sorted[sorted.count / 2] / 1_000))
            PerfBuild.gauge("composer.\(size).p95.us", Int(sorted[sorted.count * 95 / 100] / 1_000))
            PerfBuild.gauge("composer.\(size).max.us", Int(sorted[sorted.count - 1] / 1_000))
            PerfBuild.gauge("composer.\(size).inlineChips", view.string.unicodeScalars.count(where: { $0.value == 0xFFFC }))
        }
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
}
#endif
