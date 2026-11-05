import Foundation
import Testing
@testable import RemoteCoderCore

struct FleetLiveActivityPlanTests {
    private let mini = UUID(uuidString: "CCCCCCCC-0000-4000-8000-000000000001")!
    private let book = UUID(uuidString: "DDDDDDDD-0000-4000-8000-000000000002")!
    private let linux = UUID(uuidString: "EEEEEEEE-0000-4000-8000-000000000003")!

    @Test func restorationAdoptsOneLiveFleetActivityAndRetiresEveryOther() {
        let restoration = FleetLiveActivityPlan.restore([
            .init(id: "per-host", coordinatorID: nil, isLive: true),
            .init(id: "removed-coordinator", coordinatorID: linux, isLive: true),
            .init(id: "ended", coordinatorID: mini, isLive: false),
            .init(id: "fleet", coordinatorID: mini, isLive: true),
            .init(id: "duplicate", coordinatorID: book, isLive: true),
        ], configured: [mini, book])
        #expect(restoration.adopted == "fleet")
        #expect(restoration.ended == ["per-host", "removed-coordinator", "ended", "duplicate"])
    }

    @Test func coordinatorPrefersTheCapableAutomationsAuthorityThenConfiguredOrder() {
        #expect(FleetLiveActivityPlan.coordinator(capable: [mini, book], preferred: book) == book)
        #expect(FleetLiveActivityPlan.coordinator(capable: [mini, book], preferred: linux) == mini)
        #expect(FleetLiveActivityPlan.coordinator(capable: [mini, book], preferred: mini, excluding: mini) == book)
        #expect(FleetLiveActivityPlan.coordinator(capable: [mini], preferred: nil, excluding: mini) == nil)
    }

    @Test func attentionRowsFromDifferentHostsKeepDistinctIdentities() {
        typealias Attention = ActiveTasksLiveActivityContent.Attention
        let rows = [mini, book].map { host in
            Attention(hostID: host, threadID: "same-thread", title: "Result", reason: .finishedUnread,
                      completedAtUnixSeconds: 20)
        }
        #expect(Set(rows.map(\.id)).count == 2)
    }

    @Test func fleetSnapshotsDecodeHostExactRowsAndCoverage() throws {
        let snapshot = try JSONDecoder().decode(ActiveTasksLiveActivitySnapshot.self, from: Data(#"""
            {"epoch":"e","revision":3,"relevanceScore":100,"updatedAtUnixSeconds":1300,
             "content":{"activeTaskCount":2,"attentionCount":1,"unavailableHostIDs":["dddddddd-0000-4000-8000-000000000002"],
               "attention":[{"hostID":"cccccccc-0000-4000-8000-000000000001","threadID":"done",
                             "reason":"finishedUnread","completedAtUnixSeconds":1300}]}}
            """#.utf8))
        #expect(snapshot.content.attention.map(\.hostID) == [mini])
        #expect(snapshot.content.unavailableHostIDs == [book])
        #expect(!snapshot.content.isEmpty)
    }

    @Test func onlyAZeroViewWithEveryHostCurrentIsCertifiedEmpty() {
        let incomplete = ActiveTasksLiveActivityContent(activeTaskCount: 0, attention: [], attentionCount: 0,
                                                        unavailableHostIDs: [book])
        let complete = ActiveTasksLiveActivityContent(activeTaskCount: 0, attention: [], attentionCount: 0,
                                                      unavailableHostIDs: [])
        #expect(incomplete.isEmpty && !incomplete.isCertifiedEmpty)
        #expect(complete.isCertifiedEmpty)
    }
}
