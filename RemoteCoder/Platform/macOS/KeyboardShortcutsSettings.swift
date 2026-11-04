#if os(macOS)
import AppKit
import SwiftUI

struct KeyboardShortcutsSettings: View {
    @Environment(\.chatKeyboardShortcuts) private var shortcuts
    @State private var error: String?

    var body: some View {
        SettingsFormPage {
            if let shortcuts {
                Section {
                    ForEach(ChatCommand.allCases, id: \.self) { command in
                        LabeledContent(command.shortcutTitle) {
                            HStack(spacing: 8) {
                                ShortcutRecorder(shortcut: shortcuts.shortcut(for: command), label: command.shortcutTitle) {
                                    assign($0, to: command, in: shortcuts)
                                }
                                .scaledFrame(width: 124, height: 24)
                                Button("Clear", systemImage: "xmark.circle.fill") {
                                    _ = assign(nil, to: command, in: shortcuts)
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .disabled(shortcuts.shortcut(for: command) == nil)
                                .accessibilityLabel("Clear \(command.shortcutTitle) shortcut")
                            }
                        }
                    }
                } footer: {
                    Text("Click a shortcut and press new keys. Use ⌘ or ⌃. Press Esc to cancel.")
                }
                Section {
                    Button("Restore Defaults") {
                        shortcuts.resetAll()
                        error = nil
                    }
                }
            }
        }
        .alert("Shortcut Unavailable", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func assign(_ shortcut: KeyboardShortcut?, to command: ChatCommand, in preferences: ChatKeyboardShortcuts) -> Bool {
        if let shortcut {
            if let conflict = preferences.conflict(for: shortcut, excluding: command) {
                error = "\(shortcut.symbols) is already used for \(conflict.shortcutTitle)."
                return false
            }
            let current = preferences.shortcut(for: command)
            if current?.key != shortcut.key || current?.modifiers != shortcut.modifiers {
                if let title = NSApp.mainMenu?.shortcutTitle(for: shortcut) {
                    error = "\(shortcut.symbols) is already used for \(title)."
                    return false
                }
                if shortcut.modifiers.contains(.command), shortcut.modifiers.isDisjoint(with: [.control, .option]),
                   shortcut.key == "=" || shortcut.key == "+" {
                    error = "\(shortcut.symbols) is already used for Zoom In."
                    return false
                }
            }
        }
        do {
            try preferences.set(shortcut, for: command)
            error = nil
            return true
        } catch {
            self.error = "Could not save the shortcut: \(error.localizedDescription)"
            return false
        }
    }
}

private extension ChatCommand {
    var shortcutTitle: String {
        switch self {
        case .toggleSidebar: "Toggle Left Sidebar"
        case .toggleInspector: "Toggle Right Sidebar"
        case .togglePin: "Pin or Unpin Conversation"
        case .settle: "Settle or Unsettle Conversation"
        default: title(in: nil)
        }
    }
}

private extension NSMenu {
    func shortcutTitle(for shortcut: KeyboardShortcut) -> String? {
        for item in items {
            if let title = item.submenu?.shortcutTitle(for: shortcut) { return title }
            let flags = item.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift])
            var modifiers = EventModifiers(flags)
            if item.keyEquivalent != item.keyEquivalent.lowercased() { modifiers.insert(.shift) }
            if item.keyEquivalent.lowercased() == String(shortcut.key.character).lowercased(), modifiers == shortcut.modifiers {
                return item.title
            }
        }
        return nil
    }
}

private extension EventModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.shift) { insert(.shift) }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: KeyboardShortcut?
    let label: String
    let record: (KeyboardShortcut?) -> Bool

    func makeNSView(context: Context) -> ShortcutRecorderButton { ShortcutRecorderButton() }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.shortcutLabel = shortcut?.symbols ?? "Record Shortcut"
        button.record = record
        button.setAccessibilityLabel("\(label) shortcut")
        button.setAccessibilityValue(shortcut?.symbols ?? "None")
    }
}

final class ShortcutRecorderButton: NSButton {
    var shortcutLabel = "Record Shortcut" { didSet { if !isRecording { title = shortcutLabel } } }
    var record: ((KeyboardShortcut?) -> Bool)?
    private var isRecording = false

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(startRecording)
        title = shortcutLabel
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    @objc private func startRecording() {
        guard window?.makeFirstResponder(self) == true else { return }
        isRecording = true
        title = "Type Shortcut…"
    }

    override func resignFirstResponder() -> Bool {
        finishRecording()
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard let characters = event.characters(byApplyingModifiers: []), characters.count == 1,
              let character = characters.lowercased().first else { return }
        let key = KeyEquivalent(character)
        if key == .escape { finishRecording(); return }
        if key == .tab {
            finishRecording()
            if flags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
            return
        }
        if flags.isEmpty, key == .delete || key == .deleteForward {
            if record?(nil) == true { finishRecording() }
            return
        }
        guard !flags.isDisjoint(with: [.command, .control]) else {
            title = "Use ⌘ or ⌃"
            return
        }
        let modifiers = EventModifiers(flags)
        if record?(KeyboardShortcut(key, modifiers: modifiers, localization: .custom)) == true {
            finishRecording()
        }
    }

    private func finishRecording() {
        isRecording = false
        title = shortcutLabel
    }
}
#endif
