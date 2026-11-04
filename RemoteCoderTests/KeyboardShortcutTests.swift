import Foundation
import SwiftUI
import Testing
@testable import RemoteCoder

@MainActor
struct KeyboardShortcutTests {
    @Test func customAndClearedShortcutsSurviveReloadAndRestore() throws {
        let domain = "KeyboardShortcutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = ChatKeyboardShortcuts(defaults: defaults)
        #expect(preferences.shortcut(for: .toggleSidebar) == KeyboardShortcut("b"))
        #expect(preferences.shortcut(for: .toggleInspector) == KeyboardShortcut("b", modifiers: [.command, .option]))
        try preferences.set(KeyboardShortcut("j", modifiers: [.command, .shift]), for: .toggleSidebar)
        try preferences.set(nil, for: .toggleInspector)

        let restored = ChatKeyboardShortcuts(defaults: defaults)
        #expect(restored.shortcut(for: .toggleSidebar)?.key == "j")
        #expect(restored.shortcut(for: .toggleSidebar)?.modifiers == [.command, .shift])
        #expect(restored.shortcut(for: .toggleInspector) == nil)
        restored.resetAll()

        let reset = ChatKeyboardShortcuts(defaults: defaults)
        #expect(reset.shortcut(for: .toggleSidebar) == KeyboardShortcut("b"))
        #expect(reset.shortcut(for: .toggleInspector) == KeyboardShortcut("b", modifiers: [.command, .option]))
    }

    @Test func conflictsIncludeDefaultsAndCustomBindingsRegardlessOfLocalization() throws {
        let domain = "KeyboardShortcutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = ChatKeyboardShortcuts(defaults: defaults)
        #expect(preferences.conflict(for: KeyboardShortcut("b", localization: .custom), excluding: .newChat) == .toggleSidebar)
        #expect(preferences.conflict(for: KeyboardShortcut("b"), excluding: .toggleSidebar) == nil)
        try preferences.set(KeyboardShortcut("j", modifiers: [.command, .shift]), for: .toggleSidebar)
        #expect(preferences.conflict(for: KeyboardShortcut("j", modifiers: [.command, .shift]), excluding: .newChat) == .toggleSidebar)
        try preferences.set(nil, for: .toggleSidebar)
        #expect(preferences.conflict(for: KeyboardShortcut("j", modifiers: [.command, .shift]), excluding: .newChat) == nil)
    }

    @Test func recordedKeysNormalizeImplicitShiftAndPhysicalBackspace() {
        let help = KeyboardShortcut(recordedCharacter: "?", modifiers: [.command, .shift])
        #expect(help.key == "?")
        #expect(help.modifiers == .command)
        let letter = KeyboardShortcut(recordedCharacter: "J", modifiers: [.command, .shift])
        #expect(letter.key == "j")
        #expect(letter.modifiers == [.command, .shift])
        let backspace = KeyboardShortcut(recordedCharacter: "\u{7f}", modifiers: [])
        #expect(backspace.key == .delete)
        #expect(backspace.modifiers.isEmpty)
        let modifiedBackspace = KeyboardShortcut(recordedCharacter: "\u{7f}", modifiers: .command)
        #expect(modifiedBackspace.key == .delete)
        #expect(modifiedBackspace.modifiers == .command)
    }

}
