import ActivityKit
import Foundation
import Testing
@testable import RemoteCoder

@MainActor
@Suite(.serialized)
struct FleetLiveActivityTests {
    private typealias Attributes = RemoteCoderActiveTasksAttributes
    private typealias Content = ActiveTasksLiveActivityContent

    private struct Unreachable: Error {}

    private final class FakeHost {
        let id = UUID()
        var isCapable = true
        var content: Content?
        var registrations: [DeviceRegistrationRequest.FleetActivity?] = []

        func host(named name: String) -> FleetLiveActivityService.Host {
            .init(
                id: id,
                name: name,
                isCoordinatorCapable: { [unowned self] in isCapable },
                read: { [unowned self] _ in
                    guard let content else { throw Unreachable() }
                    return ActiveTasksLiveActivitySnapshot(
                        epoch: "test", revision: 1, content: content,
                        relevanceScore: content.attentionCount > 0 ? 100 : 25, updatedAtUnixSeconds: 1_300
                    )
                },
                register: { [unowned self] in registrations.append($0) }
            )
        }
    }

    private func service(_ hosts: [FakeHost], preferred: UUID? = nil) -> FleetLiveActivityService {
        FleetLiveActivityService(
            hosts: { hosts.enumerated().map { $1.host(named: "Host \($0)") } },
            configured: { hosts.map(\.id) },
            preferred: { preferred }
        )
    }

    private func liveActivities() -> [Activity<Attributes>] {
        Activity<Attributes>.activities.filter { [.active, .stale].contains($0.activityState) }
    }

    private func endAll() async {
        for activity in Activity<Attributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func running(_ count: Int, on host: UUID) -> Content {
        let row = Content.Attention(hostID: host, threadID: "done", title: "Fix login", reason: .finishedUnread,
                                    completedAtUnixSeconds: 1_300)
        return Content(activeTaskCount: count, attention: [row], attentionCount: 1, unavailableHostIDs: [])
    }

    @Test func attributesFromPerHostBuildsDecodeWithoutAFleet() throws {
        let decoded = try JSONDecoder().decode(Attributes.self, from: Data(#"""
            {"startedAt":0,"hostID":"CCCCCCCC-0000-0000-0000-000000000001","hostName":"Mini"}
            """#.utf8))
        #expect(decoded.fleet == nil)
    }

    @Test func fleetStateDecodesRowHostsAndCoverage() throws {
        let state = try JSONDecoder().decode(Attributes.ContentState.self, from: Data(#"""
            {"activeTaskCount":2,"attentionCount":4,"updatedAtUnixSeconds":0,
             "unavailableHostIDs":["bbbbbbbb-0000-4000-8000-00000000000b"],"attention":[
              {"hostID":"aaaaaaaa-0000-4000-8000-00000000000a","threadID":"done","title":"Fix login",
               "reason":"finishedUnread","completedAtUnixSeconds":1300},
              {"threadID":"asking","reason":"question"}]}
            """#.utf8))
        let rows = try #require(state.attention)
        #expect(rows.map(\.hostID) == [UUID(uuidString: "AAAAAAAA-0000-4000-8000-00000000000A"), nil])
        #expect(rows.map(\.reason) == [.finishedUnread, .question])
        #expect(state.unavailableHostIDs == [UUID(uuidString: "BBBBBBBB-0000-4000-8000-00000000000B")].compactMap { $0 })
        let fleet = Attributes(startedAt: .distantPast, fleet: .init(
            coordinatorID: UUID(), hosts: [.init(id: try #require(state.unavailableHostIDs?.first), name: "MacBook")]
        ))
        #expect(fleet.unavailableSummary(for: state) == "MacBook unavailable")
    }

    @Test func anOlderPayloadDecodesWithoutRowsOrCoverage() throws {
        let state = try JSONDecoder().decode(Attributes.ContentState.self, from: Data(#"""
            {"activeTaskCount":1,"updatedAtUnixSeconds":0,"topTasks":[{"startedAtUnixSeconds":10,"threadID":"t"}]}
            """#.utf8))
        #expect(state.activeTaskCount == 1)
        #expect(state.attention == nil)
        #expect(state.unavailableHostIDs == nil)
        #expect(Attributes(startedAt: .distantPast, fleet: nil).unavailableSummary(for: state) == nil)
    }

    @Test func thePreferredCoordinatorsContentAppearsFromTheFirstFrame() async throws {
        await endAll()
        defer { Task { await endAll() } }
        let first = FakeHost()
        let preferred = FakeHost()
        preferred.content = running(2, on: preferred.id)
        let service = service([first, preferred], preferred: preferred.id)
        defer { service.retire() }
        await service.settle()
        let activity = try #require(liveActivities().first)
        #expect(activity.attributes.fleet?.coordinatorID == preferred.id)
        #expect(activity.attributes.fleet?.hosts.map(\.id) == [first.id, preferred.id])
        #expect(activity.content.state.activeTaskCount == 2)
        #expect(activity.content.state.attention == preferred.content?.attention)
        #expect(activity.content.relevanceScore == 100)
    }

    @Test func certifiedEmptyContentRequestsNothing() async {
        await endAll()
        let host = FakeHost()
        host.content = Content(activeTaskCount: 0, attention: [], attentionCount: 0, unavailableHostIDs: [])
        let service = service([host])
        defer { service.retire() }
        await service.settle()
        #expect(liveActivities().isEmpty)
    }

    @Test func aZeroViewWithAnUnavailableHostRequestsNothing() async {
        await endAll()
        let host = FakeHost()
        let missing = UUID()
        host.content = Content(activeTaskCount: 0, attention: [], attentionCount: 0, unavailableHostIDs: [missing])
        let service = service([host])
        defer { service.retire() }
        await service.settle()
        #expect(liveActivities().isEmpty)
    }

    @Test func perHostActivitiesFromEarlierBuildsAreRetired() async throws {
        await endAll()
        let legacy = try Activity<Attributes>.request(
            attributes: Attributes(startedAt: .now, fleet: nil),
            content: ActivityContent(state: .init(activeTaskCount: 1, attention: nil, attentionCount: nil,
                                                  unavailableHostIDs: nil, updatedAtUnixSeconds: 0), staleDate: nil)
        )
        let host = FakeHost()
        let service = service([host])
        defer { service.retire() }
        await service.settle()
        #expect(liveActivities().allSatisfy { $0.id != legacy.id })
    }

    @Test func aCoordinatorLostWhileActiveHandsTheActivityToAnotherHostOnTheNextHint() async throws {
        await endAll()
        defer { Task { await endAll() } }
        let coordinator = FakeHost()
        let replacement = FakeHost()
        coordinator.content = running(1, on: coordinator.id)
        replacement.content = running(1, on: coordinator.id)
        let service = service([coordinator, replacement], preferred: coordinator.id)
        defer { service.retire() }
        await service.settle()
        #expect(liveActivities().map(\.attributes.fleet?.coordinatorID) == [coordinator.id])

        coordinator.content = nil
        await service.settle()
        let moved = try #require(liveActivities().first)
        #expect(liveActivities().count == 1)
        #expect(moved.attributes.fleet?.coordinatorID == replacement.id)
    }
}
