import ActivityKit
import Foundation
import Testing
@testable import RemoteCoder

/// Each host runs its own aggregate "active tasks" activity, so an idle host
/// must never touch another host's.
struct ActiveTasksLiveActivityScopeTests {
    private let mini = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!

    @Test func attributesFromEarlierBuildsDecodeAsLegacy() throws {
        let decoded = try JSONDecoder().decode(RemoteCoderActiveTasksAttributes.self, from: Data(#"{"startedAt":0}"#.utf8))
        #expect(decoded.hostID == nil)
        #expect(ActiveTasksLiveActivityScope.isLegacy(activityHostID: decoded.hostID))
        #expect(ActiveTasksLiveActivityScope.mayEnd(activityHostID: decoded.hostID, serviceHostID: mini))
    }

    @Test func gatewayAttentionRowsDecode() throws {
        let state = try JSONDecoder().decode(RemoteCoderActiveTasksAttributes.ContentState.self, from: Data(#"""
            {"activeTaskCount":2,"attentionCount":4,"updatedAtUnixSeconds":0,"attention":[
              {"threadID":"done","accountID":"81C84F21-818E-4AF5-9B5F-7413A3EA4FDE","title":"Fix login",
               "reason":"finishedUnread","completedAtUnixSeconds":1300},
              {"threadID":"asking","reason":"question"}]}
            """#.utf8))
        let rows = try #require(state.attention)
        #expect(rows.map(\.reason) == [.finishedUnread, .question])
        #expect(rows.map(\.title) == ["Fix login", nil])
        #expect(rows.map(\.completedAtUnixSeconds) == [1300, nil])
        #expect(rows.first?.accountID == UUID(uuidString: "81C84F21-818E-4AF5-9B5F-7413A3EA4FDE"))
        #expect(state.attentionCount == 4)
    }

    @Test func anOlderGatewaysTaskPayloadDecodesWithoutAttention() throws {
        let state = try JSONDecoder().decode(RemoteCoderActiveTasksAttributes.ContentState.self, from: Data(#"""
            {"activeTaskCount":1,"updatedAtUnixSeconds":0,"topTasks":[{"startedAtUnixSeconds":10,"threadID":"t"}]}
            """#.utf8))
        #expect(state.activeTaskCount == 1)
        #expect(state.attention == nil)
        #expect(state.attentionCount == nil)
    }

    @Test(arguments: [ActiveTasksLiveActivityContent.Attention.Reason.finishedUnread, .question])
    func attentionOnlyRequestsUseGatewayContentFromTheFirstFrame(reason: ActiveTasksLiveActivityContent.Attention.Reason) async throws {
        let host = UUID()
        let service = ActiveTasksLiveActivityService(hostID: host, hostName: "Attention test", legacyHostIDs: [])
        defer { await service.end() }
        let row = ActiveTasksLiveActivityContent.Attention(
            threadID: "attention", accountID: nil, title: "Needs you", reason: reason,
            completedAtUnixSeconds: reason == .finishedUnread ? 1_300 : nil
        )
        await service.receive(ActiveTasksLiveActivitySnapshot(
            epoch: "test", revision: 1,
            content: ActiveTasksLiveActivityContent(activeTaskCount: 0, attention: [row], attentionCount: 1),
            relevanceScore: reason == .finishedUnread ? 100 : 75,
            updatedAtUnixSeconds: 1_300
        ))
        await service.sync(requestsActivity: true, now: .now, onPushTokenUpdate: { _ in }, onEnded: {})
        let activity = try #require(Activity<RemoteCoderActiveTasksAttributes>.activities.first { $0.attributes.hostID == host })
        #expect(activity.content.state.activeTaskCount == 0)
        #expect(activity.content.state.attention == [row])
        #expect(activity.content.state.attentionCount == 1)
        #expect(activity.content.relevanceScore == (reason == .finishedUnread ? 100 : 75))
    }
    @Test func unavailableContentBlocksAStartFromThePreviousProjection() async {
        let host = UUID()
        let service = ActiveTasksLiveActivityService(hostID: host, hostName: "Unavailable test", legacyHostIDs: [])
        defer { await service.end() }
        let content = ActiveTasksLiveActivitySnapshot(
            epoch: "test", revision: 1,
            content: ActiveTasksLiveActivityContent(activeTaskCount: 1, attention: [], attentionCount: 0),
            relevanceScore: 25, updatedAtUnixSeconds: 1_300
        )
        await service.receive(content)
        await service.receive(nil)
        await service.sync(requestsActivity: true, now: .now, onPushTokenUpdate: { _ in }, onEnded: {})
        #expect(Activity<RemoteCoderActiveTasksAttributes>.activities.allSatisfy { $0.attributes.hostID != host })
    }

    @Test func anOlderReadCannotClearANewerGatewayProjection() async throws {
        let host = UUID()
        let service = ActiveTasksLiveActivityService(hostID: host, hostName: "Read fence test", legacyHostIDs: [])
        defer { await service.end() }
        let started = AsyncStream<Void>.makeStream()
        let responses = AsyncStream<ActiveTasksLiveActivitySnapshot?>.makeStream()
        let refresh = Task {
            try await service.refresh {
                started.continuation.yield(())
                var reader = responses.stream.makeAsyncIterator()
                return await reader.next() ?? nil
            }
        }
        defer { refresh.cancel(); started.continuation.finish(); responses.continuation.finish() }
        var reader = started.stream.makeAsyncIterator()
        _ = await reader.next()
        let row = ActiveTasksLiveActivityContent.Attention(
            threadID: "fresh", accountID: nil, title: nil, reason: .question, completedAtUnixSeconds: nil
        )
        await service.receive(ActiveTasksLiveActivitySnapshot(
            epoch: "test", revision: 2,
            content: ActiveTasksLiveActivityContent(activeTaskCount: 0, attention: [row], attentionCount: 1),
            relevanceScore: 75, updatedAtUnixSeconds: 1_300
        ))
        responses.continuation.yield(nil)
        try await refresh.value
        await service.sync(requestsActivity: true, now: .now, onPushTokenUpdate: { _ in }, onEnded: {})
        let activity = try #require(Activity<RemoteCoderActiveTasksAttributes>.activities.first { $0.attributes.hostID == host })
        #expect(activity.content.state.attention == [row])
    }
    @Test func mainActivityCreationControl() async throws {
        let host = UUID()
        let service = ActiveTasksLiveActivityService(hostID: host, hostName: "Main control", legacyHostIDs: [])
        defer { await service.end() }
        await service.receive(ActiveTasksLiveActivitySnapshot(
            epoch: "control", revision: 1,
            content: ActiveTasksLiveActivityContent(activeTaskCount: 1, attention: [], attentionCount: 0),
            relevanceScore: 25, updatedAtUnixSeconds: Date.now.timeIntervalSince1970
        ))
        await service.sync(requestsActivity: true, now: .now, onPushTokenUpdate: { _ in }, onEnded: {})
        let activity = try #require(Activity<RemoteCoderActiveTasksAttributes>.activities.first {
            $0.attributes.hostID == host
        })
        #expect(activity.content.state.activeTaskCount == 1)
    }

}
