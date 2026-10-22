import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct PreferenceSyncTests {
    private static let keys: Set<String> = ["theme", "autoSpeak"]

    @Test func aChoiceOnOneDeviceReachesAnotherThroughTheHost() async throws {
        let phone = try Device()
        let mac = try Device()
        mac.defaults.set("dusk", forKey: "theme")
        let host = FakePreferenceHost()

        let phoneStore = SyncedPreferenceStore(defaults: phone.defaults, keys: Self.keys)
        let macStore = SyncedPreferenceStore(defaults: mac.defaults, keys: Self.keys)
        phone.defaults.set("dawn", forKey: "theme")
        var macReloads = 0
        macStore.onExternalChange = { macReloads += 1 }
        await SyncedPreferenceExchange(gateway: host, store: phoneStore, hostLabel: "Mini").settle()
        let macSync = SyncedPreferenceExchange(gateway: host, store: macStore, hostLabel: "Mini")
        await macSync.settle()

        #expect(mac.defaults.string(forKey: "theme") == "dawn")
        #expect(macReloads == 1)

        mac.defaults.set(true, forKey: "autoSpeak")
        mac.defaults.removeObject(forKey: "theme")
        await macSync.settle()
        let hostEntries = await host.entries
        #expect(hostEntries["autoSpeak"]?.value == .bool(true))
        #expect(hostEntries["theme"]?.value == .null)

        phoneStore.merge(PreferenceDocument(entries: hostEntries))
        #expect(phone.defaults.bool(forKey: "autoSpeak"))
        #expect(phone.defaults.object(forKey: "theme") == nil)
        #expect(phoneStore.pending(forHost: PreferenceDocument(entries: hostEntries)).isEmpty)
        #expect(await host.updates == 2)
    }

    @Test func aRelaunchedDeviceKeepsItsNewerChoiceOverAStaleHostValue() async throws {
        let phone = try Device()
        let host = FakePreferenceHost()
        let store = SyncedPreferenceStore(defaults: phone.defaults, keys: Self.keys)
        phone.defaults.set("dawn", forKey: "theme")
        await SyncedPreferenceExchange(gateway: host, store: store, hostLabel: "Mini").settle()
        await host.set("theme", PreferenceEntry(value: .string("dusk"), updatedAt: 1, device: "mac"))

        let relaunched = SyncedPreferenceStore(defaults: phone.defaults, keys: Self.keys)
        await SyncedPreferenceExchange(gateway: host, store: relaunched, hostLabel: "Mini").settle()

        #expect(phone.defaults.string(forKey: "theme") == "dawn")
        #expect(await host.entries["theme"]?.value == .string("dawn"))
    }

    @Test func aDeviceRelaysEachHostsChangeToTheOtherHosts() async throws {
        let phone = try Device()
        let mini = FakePreferenceHost()
        let macBook = FakePreferenceHost()
        await mini.set("theme", PreferenceEntry(value: .string("dusk"), updatedAt: 6, device: "mac-a"))
        await macBook.set("theme", PreferenceEntry(value: .string("dawn"), updatedAt: 5, device: "mac-b"))
        await macBook.set("autoSpeak", PreferenceEntry(value: .bool(true), updatedAt: 7, device: "mac-b"))
        let store = SyncedPreferenceStore(defaults: phone.defaults, keys: Self.keys)
        let miniSync = SyncedPreferenceExchange(gateway: mini, store: store, hostLabel: "Mini")
        let macBookSync = SyncedPreferenceExchange(gateway: macBook, store: store, hostLabel: "MacBook")
        var relays: [Task<Void, Never>] = []
        store.onReplicaChange = { relays += [miniSync.sync(), macBookSync.sync()].compactMap { $0 } }

        await miniSync.settle()
        while let relay = relays.popLast() { await relay.value }

        let expected: [String: PreferenceEntry] = [
            "theme": PreferenceEntry(value: .string("dusk"), updatedAt: 6, device: "mac-a"),
            "autoSpeak": PreferenceEntry(value: .bool(true), updatedAt: 7, device: "mac-b"),
        ]
        #expect(await mini.entries == expected)
        #expect(await macBook.entries == expected)
        #expect(phone.defaults.string(forKey: "theme") == "dusk")
        #expect(phone.defaults.bool(forKey: "autoSpeak"))
    }

    @Test func drawerFoldsPersistLocallyAndCollapseAllIncludesAutomations() async throws {
        let phone = try Device()
        let mac = try Device()
        let drawer = ConversationDrawerPreferences(defaults: phone.defaults)
        #expect(!drawer.isAutomationsFolded)
        drawer.setAllFolded(true, projects: ["site"])
        let restored = ConversationDrawerPreferences(defaults: phone.defaults)
        #expect(restored.isAutomationsFolded && restored.isPinnedFolded && restored.isSettledFolded)
        #expect(restored.foldedProjects == ["site"])
        let host = FakePreferenceHost()
        let store = SyncedPreferenceStore(defaults: phone.defaults, keys: ConversationDrawerPreferences.syncedKeys)
        drawer.mode = .projects
        await SyncedPreferenceExchange(gateway: host, store: store, hostLabel: "Mini").settle()
        let other = SyncedPreferenceStore(defaults: mac.defaults, keys: ConversationDrawerPreferences.syncedKeys)
        await SyncedPreferenceExchange(gateway: host, store: other, hostLabel: "Mini").settle()
        let otherDrawer = ConversationDrawerPreferences(defaults: mac.defaults)
        #expect(otherDrawer.mode == .projects)
        #expect(!otherDrawer.isAutomationsFolded && !otherDrawer.isPinnedFolded)
        drawer.setAllFolded(false, projects: ["site"])
        let expanded = ConversationDrawerPreferences(defaults: phone.defaults)
        #expect(!expanded.isAutomationsFolded && !expanded.isPinnedFolded && !expanded.isSettledFolded)
        #expect(expanded.foldedProjects.isEmpty)
    }

    @Test func aResetFromAnotherDeviceShowsTheDefaultWithoutBecomingAChoice() throws {
        let phone = try Device()
        let speech = SpeechPreferences(defaults: phone.defaults)
        let drawer = ConversationDrawerPreferences(defaults: phone.defaults)
        speech.isAutoSpeakEnabled = true
        drawer.mode = .projects
        let keys = ConversationDrawerPreferences.syncedKeys.union([SpeechPreferences.autoSpeakKey])
        let store = SyncedPreferenceStore(defaults: phone.defaults, keys: keys)
        store.onExternalChange = {
            speech.reload()
            drawer.reloadMode()
        }
        let reset = PreferenceDocument(entries: Dictionary(uniqueKeysWithValues: keys.map {
            ($0, PreferenceEntry(value: .null, updatedAt: 5, device: "mac"))
        }))

        store.merge(reset)

        #expect(!speech.isAutoSpeakEnabled)
        #expect(drawer.mode == .priority)
        #expect(keys.allSatisfy { phone.defaults.object(forKey: $0) == nil })
        #expect(store.pending(forHost: reset).isEmpty)
    }
}

private extension SyncedPreferenceExchange {
    func settle() async {
        await sync()?.value
    }
}

private final class Device {
    let defaults: UserDefaults
    private let suite = "PreferenceSyncTests.\(UUID().uuidString)"

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
    }
}

private actor FakePreferenceHost: SyncedPreferenceRemote {
    private(set) var entries: [String: PreferenceEntry] = [:]
    private(set) var updates = 0

    func set(_ key: String, _ entry: PreferenceEntry) {
        entries[key] = entry
    }

    func readPreferences() -> PreferenceDocument {
        PreferenceDocument(entries: entries)
    }

    func updatePreferences(_ received: [String: PreferenceEntry]) -> PreferenceDocument {
        updates += 1
        for (key, entry) in received where entries[key].map(entry.supersedes) ?? true {
            entries[key] = entry
        }
        return PreferenceDocument(entries: entries)
    }
}
