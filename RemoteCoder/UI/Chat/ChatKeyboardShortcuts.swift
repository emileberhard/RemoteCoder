import Observation
import SwiftUI

@MainActor
@Observable
final class ChatKeyboardShortcuts {
    private struct Override: Codable {
        let key: String?
        let modifiers: Int

        init(_ shortcut: KeyboardShortcut?) {
            key = shortcut.map { String($0.key.character) }
            modifiers = shortcut?.modifiers.rawValue ?? 0
        }

        var shortcut: KeyboardShortcut? {
            guard let key, key.count == 1, let character = key.first else { return nil }
            return KeyboardShortcut(KeyEquivalent(character), modifiers: EventModifiers(rawValue: modifiers), localization: .custom)
        }
    }

    private static let storageKey = "keyboard.chatShortcuts"
    @ObservationIgnored private let defaults: UserDefaults
    private var overrides: [String: Override]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        overrides = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([String: Override].self, from: $0) } ?? [:]
    }

    func shortcut(for command: ChatCommand) -> KeyboardShortcut? {
        if let override = overrides[command.rawValue] { return override.shortcut }
        return command.shortcut
    }

    func conflict(for shortcut: KeyboardShortcut, excluding command: ChatCommand) -> ChatCommand? {
        ChatCommand.allCases.first { candidate in
            guard candidate != command, let binding = self.shortcut(for: candidate) else { return false }
            return binding.key == shortcut.key && binding.modifiers == shortcut.modifiers
        }
    }

    func set(_ shortcut: KeyboardShortcut?, for command: ChatCommand) throws {
        var updated = overrides
        updated[command.rawValue] = Override(shortcut)
        try save(updated)
    }

    func resetAll() {
        defaults.removeObject(forKey: Self.storageKey)
        overrides = [:]
    }

    private func save(_ updated: [String: Override]) throws {
        let data = try JSONEncoder().encode(updated)
        defaults.set(data, forKey: Self.storageKey)
        overrides = updated
    }
}

extension EnvironmentValues {
    @Entry var chatKeyboardShortcuts: ChatKeyboardShortcuts?
}

extension ChatCommand {
    @MainActor func shortcut(in preferences: ChatKeyboardShortcuts?) -> KeyboardShortcut? {
        if let preferences { return preferences.shortcut(for: self) }
        return shortcut
    }
}
