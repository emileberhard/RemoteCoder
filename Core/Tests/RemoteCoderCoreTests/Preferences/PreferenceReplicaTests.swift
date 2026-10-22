import Foundation
import Testing
@testable import RemoteCoderCore

struct PreferenceReplicaTests {
    @Test func aLocalEditOutranksTheVersionItReplacesEvenWithASlowClock() {
        var replica = PreferenceReplica(device: "phone")
        _ = replica.merge(["theme": PreferenceEntry(value: .string("dawn"), updatedAt: 500, device: "mac")])

        replica.record("theme", value: .string("dusk"), at: 100)

        #expect(replica.entries["theme"] == PreferenceEntry(value: .string("dusk"), updatedAt: 501, device: "phone"))
    }

    @Test func onlyNewerEntriesApplyAndTiesFallToTheGreaterDevice() {
        var replica = PreferenceReplica(device: "mac")
        replica.record("theme", value: .string("dawn"), at: 200)

        let stale = replica.merge(["theme": PreferenceEntry(value: .string("old"), updatedAt: 100, device: "phone")])
        let tie = replica.merge(["theme": PreferenceEntry(value: .string("tie"), updatedAt: 200, device: "phone")])

        #expect(stale.isEmpty)
        #expect(tie == ["theme": .string("tie")])
        #expect(replica.newer(than: ["theme": PreferenceEntry(value: .string("tie"), updatedAt: 200, device: "phone")]).isEmpty)
    }

    @Test func adoptedValuesStayOnTheDeviceUntilAnyChangeReplacesThem() {
        var replica = PreferenceReplica(device: "phone")
        replica.adopt("voice", value: .string("marin"))
        replica.adopt("theme", value: .string("dawn"))

        #expect(replica.newer(than: [:]).isEmpty)
        #expect(replica.merge(["theme": PreferenceEntry(value: .string("dusk"), updatedAt: 1, device: "mac")])
            == ["theme": .string("dusk")])
        #expect(replica.entries["voice"]?.value == .string("marin"))
    }

    @Test func userDefaultsValuesRoundTripThroughJSON() throws {
        let suite = "PreferenceReplicaTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "flag")
        defaults.set(["group": "Work"], forKey: "names")

        let flag = JSONValue(propertyList: try #require(defaults.object(forKey: "flag")))
        let names = JSONValue(propertyList: try #require(defaults.object(forKey: "names")))

        #expect(flag == .bool(true))
        #expect(names == .object(["group": .string("Work")]))
        #expect(JSONValue.array([.string("a"), .null]).propertyList == nil)
    }
}
