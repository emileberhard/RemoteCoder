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
    static let noAnswer = GatewayConnectivity.unreachable(.noAnswer)

    static let rows: [Row] = [
        Row(name: "connected", connectivity: .connected(.relay), role: .stationary, at: 0, reach: .connected(.relay)),
        Row(name: "restarting", connectivity: .restarting, role: .stationary, at: 0, reach: .restarting),
        Row(name: "background disconnect", connectivity: .disconnected, role: .stationary, at: 3600, reach: .connecting),
        Row(name: "credentials rejected", connectivity: .unreachable(.credentialsRejected), role: .portable, at: 0,
            reach: .credentialsRejected),
        Row(name: "portable stays calm", connectivity: noAnswer, role: .portable, at: 86_400, reach: .offline),
        Row(name: "unknown role stays calm", connectivity: noAnswer, role: .unknown, at: 86_400, reach: .offline),
        Row(name: "stationary inside grace", connectivity: noAnswer, role: .stationary, at: 299, reach: .offline, changesAt: 300),
        Row(name: "stationary at grace", connectivity: noAnswer, role: .stationary, at: 300, reach: .unreachable),
        Row(name: "peer sees it", connectivity: noAnswer, role: .portable, peerSawAt: 40, at: 60,
            reach: .unreachableFromHere, changesAt: 160),
        Row(name: "peer view outlived", connectivity: noAnswer, role: .portable, peerSawAt: 40, at: 160, reach: .offline),
        Row(name: "peer view before the peer could notice", connectivity: noAnswer, role: .portable, peerSawAt: 10, at: 20,
            reach: .offline),
        Row(name: "peer view from before the loss", connectivity: noAnswer, role: .stationary, peerSawAt: -1, at: 400,
            reach: .unreachable),
    ]

    @Test(arguments: rows) func derive(_ row: Row) {
        let lastSeen = Self.lost.addingTimeInterval(-5)
        let derived = HostAvailability.derive(connectivity: row.connectivity, role: row.role, lastSeen: lastSeen,
                                              unreachableSince: Self.lost, tasksRunningAtLoss: 2,
                                              peerSawAt: row.peerSawAt.map { Self.lost + $0 }, now: Self.lost + row.at)
        #expect(derived.availability == HostAvailability(reach: row.reach, lastSeen: lastSeen, tasksRunningAtLoss: 2))
        #expect(derived.changesAt == row.changesAt.map { Self.lost + $0 })
    }

    @Test(arguments: [(true, HostRole.portable), (false, .stationary)] as [(Bool?, HostRole)] + [(nil, .unknown)])
    func role(_ battery: Bool?, _ role: HostRole) {
        #expect(HostRole(internalBattery: battery) == role)
    }
}

@MainActor
private final class TestClock {
    var offset: TimeInterval = 0
    private var sleepers: [CheckedContinuation<Void, Never>] = []
    private var unseenSleeps = 0
    private var sleepObserver: CheckedContinuation<Void, Never>?

    func now() -> Date { .now + offset }

    func sleep(_: Duration) async throws {
        try Task.checkCancellation()
        unseenSleeps += 1
        sleepObserver?.resume()
        sleepObserver = nil
        await withCheckedContinuation { sleepers.append($0) }
        try Task.checkCancellation()
    }

    func nextSleep() async {
        if unseenSleeps == 0 { await withCheckedContinuation { sleepObserver = $0 } }
        unseenSleeps -= 1
    }

    func wake() {
        let sleeping = sleepers
        sleepers = []
        sleeping.forEach { $0.resume() }
    }
}

@MainActor
struct HostAvailabilityTrackerTests {
    private func withTracker(_ body: @MainActor (HostAvailabilityTracker, TestClock, () -> HostAvailabilityTracker) async throws -> Void) async throws {
        let suiteName = "RemoteCoderCoreTests.HostAvailability.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let hostID = UUID()
        let clock = TestClock()
        var trackers: [HostAvailabilityTracker] = []
        let relaunch = {
            let tracker = HostAvailabilityTracker(hostID: hostID, defaults: defaults, now: clock.now, sleep: clock.sleep)
            trackers.append(tracker)
            return tracker
        }
        defer {
            trackers.forEach { $0.retire() }
            clock.wake()
        }
        try await body(relaunch(), clock, relaunch)
    }

    @Test func aStationaryHostWarnsOnceTheGraceRunsOut() async throws {
        try await withTracker { tracker, clock, _ in
            tracker.reported(internalBattery: false)
            tracker.connectivityChanged(.connected(.lan), runningTasks: 0)
            tracker.connectivityChanged(.unreachable(.noAnswer), runningTasks: 1)
            #expect(tracker.current.reach == .offline)
            #expect(tracker.current.tasksRunningAtLoss == 1)
            await clock.nextSleep()
            clock.offset = HostAvailability.warningGrace
            clock.wake()
            await clock.nextSleep()
            #expect(tracker.current.reach == .unreachable)
        }
    }

    @Test func theGraceSurvivesTheAppsOwnDisconnect() async throws {
        try await withTracker { tracker, clock, _ in
            tracker.reported(internalBattery: false)
            tracker.connectivityChanged(.connected(.lan), runningTasks: 0)
            tracker.connectivityChanged(.unreachable(.noAnswer), runningTasks: 0)
            tracker.connectivityChanged(.disconnected, runningTasks: 0)
            #expect(tracker.current.reach == .connecting)
            clock.offset = HostAvailability.warningGrace + 1
            tracker.connectivityChanged(.unreachable(.noAnswer), runningTasks: 0)
            #expect(tracker.current.reach == .unreachable)
        }
    }

    @Test func theGraceSurvivesARelaunch() async throws {
        try await withTracker { tracker, clock, relaunch in
            tracker.reported(internalBattery: false)
            tracker.connectivityChanged(.connected(.lan), runningTasks: 0)
            tracker.connectivityChanged(.unreachable(.noAnswer), runningTasks: 0)
            clock.offset = HostAvailability.warningGrace + 1
            let relaunched = relaunch()
            relaunched.connectivityChanged(.unreachable(.noAnswer), runningTasks: 0)
            #expect(relaunched.current.reach == .unreachable)
        }
    }

    @Test func reconnectingEndsTheEpisode() async throws {
        try await withTracker { tracker, clock, _ in
            tracker.reported(internalBattery: false)
            tracker.connectivityChanged(.unreachable(.noAnswer), runningTasks: 0)
            tracker.connectivityChanged(.connected(.relay), runningTasks: 0)
            clock.offset = HostAvailability.warningGrace + 1
            tracker.connectivityChanged(.unreachable(.noAnswer), runningTasks: 0)
            #expect(tracker.current.reach == .offline)
            #expect(tracker.current.tasksRunningAtLoss == 0)
        }
    }

    @Test func thePeerIsAskedOnlyOnceItCouldHaveNoticedAndBeforeItsViewExpires() async throws {
        try await withTracker { tracker, clock, _ in
            var peerViewRequests = 0
            tracker.requestsPeerView = { peerViewRequests += 1 }
            let lost = clock.now()
            tracker.connectivityChanged(.unreachable(.noAnswer), runningTasks: 0)
            #expect(peerViewRequests == 0)
            clock.offset = HostAvailability.peerLossDetection + 1
            tracker.peerSighted(at: lost + 10)
            #expect(peerViewRequests == 1)
            #expect(tracker.current.reach == .offline)
            clock.offset = HostAvailability.peerLossDetection + 10
            tracker.peerSighted(at: lost + HostAvailability.peerLossDetection + 5)
            #expect(tracker.current.reach == .unreachableFromHere)
            clock.offset = HostAvailability.peerLossDetection + 1 + HostAvailability.peerFreshness / 2
            tracker.peerSighted(at: lost + HostAvailability.peerLossDetection + 6)
            #expect(peerViewRequests == 2)
            #expect(tracker.current.reach == .unreachableFromHere)
        }
    }

    @Test func roleAndLastSeenSurviveARelaunchAndRetirementFreezesTheValue() async throws {
        try await withTracker { tracker, _, relaunch in
            #expect(tracker.role == .unknown)
            #expect(tracker.current.lastSeen == nil)
            tracker.reported(internalBattery: true)
            tracker.reported(internalBattery: nil)
            tracker.connectivityChanged(.connected(.lan), runningTasks: 0)
            let seen = try #require(tracker.current.lastSeen)

            let relaunched = relaunch()
            #expect(relaunched.role == .portable)
            #expect(relaunched.current == HostAvailability(reach: .connecting, lastSeen: seen, tasksRunningAtLoss: 0))
            relaunched.retire()
            relaunched.connectivityChanged(.connected(.lan), runningTasks: 0)
            #expect(relaunched.current.reach == .connecting)
        }
    }
}
