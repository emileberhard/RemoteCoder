import Foundation
import Testing
@testable import RemoteCoderCore

struct HostAvailabilityTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let connectivity: GatewayConnectivity
        let role: HostRole
        var peerSawAt: TimeInterval? = nil
        let at: TimeInterval
        let reach: HostAvailability.Reach
        var changesAt: TimeInterval? = nil
        var testDescription: String { name }
    }

    static let lost = Date(timeIntervalSince1970: 1_000_000)
    static func noAnswer(_ cause: GatewayConnectionFailure.Cause = .noAnswer) -> GatewayConnectivity {
        .unreachable(GatewayConnectionFailure(cause: cause, since: lost))
    }

    static let rows: [Row] = [
        Row(name: "connected", connectivity: .connected(.relay), role: .stationary, at: 0, reach: .connected(.relay)),
        Row(name: "restarting", connectivity: .restarting, role: .stationary, at: 0, reach: .restarting),
        Row(name: "background disconnect", connectivity: .disconnected, role: .stationary, at: 3600, reach: .connecting),
        Row(name: "credentials rejected", connectivity: noAnswer(.credentialsRejected), role: .portable, at: 0,
            reach: .needsAttention(.credentialsRejected)),
        Row(name: "refused", connectivity: noAnswer(.refused), role: .unknown, at: 0, reach: .needsAttention(.refused)),
        Row(name: "portable stays calm", connectivity: noAnswer(), role: .portable, at: 86_400, reach: .offline),
        Row(name: "unknown role stays calm", connectivity: noAnswer(), role: .unknown, at: 86_400, reach: .offline),
        Row(name: "stationary inside grace", connectivity: noAnswer(), role: .stationary, at: 299, reach: .offline, changesAt: 300),
        Row(name: "stationary at grace", connectivity: noAnswer(), role: .stationary, at: 300, reach: .unreachable),
        Row(name: "peer sees it", connectivity: noAnswer(), role: .portable, peerSawAt: 10, at: 60,
            reach: .unreachableFromHere, changesAt: 130),
        Row(name: "peer view outlived", connectivity: noAnswer(), role: .portable, peerSawAt: 10, at: 130, reach: .offline),
        Row(name: "peer view from before the loss", connectivity: noAnswer(), role: .stationary, peerSawAt: -1, at: 400,
            reach: .unreachable),
    ]

    @Test(arguments: rows) func derive(_ row: Row) {
        let lastSeen = Self.lost.addingTimeInterval(-5)
        let derived = HostAvailability.derive(connectivity: row.connectivity, role: row.role, lastSeen: lastSeen,
                                              tasksRunningAtLoss: 2, peerSawAt: row.peerSawAt.map { Self.lost + $0 },
                                              now: Self.lost + row.at)
        #expect(derived.availability == HostAvailability(reach: row.reach, lastSeen: lastSeen, tasksRunningAtLoss: 2))
        #expect(derived.changesAt == row.changesAt.map { Self.lost + $0 })
    }

    @Test(arguments: [(true, HostRole.portable), (false, .stationary)] as [(Bool?, HostRole)] + [(nil, .unknown)])
    func role(_ battery: Bool?, _ role: HostRole) {
        #expect(HostRole(internalBattery: battery) == role)
    }
}

@MainActor
struct HostAvailabilityTrackerTests {
    private func withTracker(_ body: @MainActor (HostAvailabilityTracker, UUID, UserDefaults) async throws -> Void) async throws {
        let suiteName = "RemoteCoderCoreTests.HostAvailability.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let hostID = UUID()
        let tracker = HostAvailabilityTracker(hostID: hostID, defaults: defaults)
        defer { tracker.retire() }
        try await body(tracker, hostID, defaults)
    }

    private func unreachable(since: Date) -> GatewayConnectivity {
        .unreachable(GatewayConnectionFailure(cause: .noAnswer, since: since))
    }

    @Test func aStationaryHostWarnsOnceTheGraceRunsOut() async throws {
        try await withTracker { tracker, _, _ in
            tracker.reported(internalBattery: false)
            tracker.connectivityChanged(.connected(.lan), runningTasks: 0)
            tracker.connectivityChanged(unreachable(since: .now - HostAvailability.warningGrace + 0.2), runningTasks: 1)
            #expect(tracker.current.reach == .offline)
            #expect(tracker.current.tasksRunningAtLoss == 1)
            #expect(await waitUntil(timeout: .seconds(3)) { tracker.current.reach == .unreachable })
        }
    }

    @Test func reconnectingCancelsThePendingWarning() async throws {
        try await withTracker { tracker, _, _ in
            tracker.reported(internalBattery: false)
            tracker.connectivityChanged(unreachable(since: .now - HostAvailability.warningGrace + 0.2), runningTasks: 0)
            tracker.connectivityChanged(.connected(.relay), runningTasks: 0)
            #expect(!(await waitUntil(timeout: .milliseconds(500)) { tracker.current.reach != .connected(.relay) }))
            tracker.connectivityChanged(.disconnected, runningTasks: 0)
            #expect(tracker.current.reach == .connecting)
            #expect(tracker.current.tasksRunningAtLoss == 0)
        }
    }

    @Test func aPeerSightingAfterTheLossMeansUnreachableFromHere() async throws {
        try await withTracker { tracker, _, _ in
            var peerViewRequests = 0
            tracker.requestsPeerView = { peerViewRequests += 1 }
            let lost = Date.now
            tracker.connectivityChanged(unreachable(since: lost), runningTasks: 0)
            #expect(peerViewRequests == 1)
            tracker.peerSighted(at: lost - 1)
            #expect(tracker.current.reach == .offline)
            tracker.peerSighted(at: .now)
            #expect(tracker.current.reach == .unreachableFromHere)
        }
    }

    @Test func roleAndLastSeenSurviveARelaunchAndRetirementFreezesTheValue() async throws {
        try await withTracker { tracker, hostID, defaults in
            #expect(tracker.role == .unknown)
            #expect(tracker.current.lastSeen == nil)
            tracker.reported(internalBattery: true)
            tracker.reported(internalBattery: nil)
            tracker.connectivityChanged(.connected(.lan), runningTasks: 0)
            let seen = try #require(tracker.current.lastSeen)

            let relaunched = HostAvailabilityTracker(hostID: hostID, defaults: defaults)
            #expect(relaunched.role == .portable)
            #expect(relaunched.current == HostAvailability(reach: .connecting, lastSeen: seen, tasksRunningAtLoss: 0))
            relaunched.retire()
            relaunched.connectivityChanged(.connected(.lan), runningTasks: 0)
            #expect(relaunched.current.reach == .connecting)
        }
    }
}
