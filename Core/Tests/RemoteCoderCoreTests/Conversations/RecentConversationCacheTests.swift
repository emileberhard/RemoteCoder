import Foundation
import Testing
@testable import RemoteCoderCore

@MainActor
struct RecentConversationCacheTests {
    private func snapshot(_ threadID: String?, text: String = "Reply") -> ConversationSnapshot {
        let message = ChatMessage(role: .codex, text: text)
        return ConversationSnapshot(conversationID: UUID(), ownerID: UUID(), threadID: threadID, revision: 1,
            messages: [message], timelines: [], items: [.message(message)], lastTurnCompletedAt: nil)
    }

    @Test func theLeastRecentlyUsedConversationLeavesFirst() {
        var cache = RecentConversationCache(capacity: 2)
        cache.record(snapshot("a"), session: nil)
        cache.record(snapshot("b"), session: nil)
        cache.record(snapshot("a", text: "Newer"), session: nil)
        cache.record(snapshot("c"), session: nil)
        #expect(cache.presentation(threadID: "b") == nil)
        #expect(cache.presentation(threadID: "a")?.messages.first?.text == "Newer")
        #expect(cache.presentation(threadID: "c") != nil)
    }

    @Test func warmedConversationsNeverDisplaceUsedOnes() {
        var cache = RecentConversationCache(capacity: 2)
        cache.record(snapshot("a"), session: nil)
        cache.record(snapshot("b"), session: nil)
        #expect(!cache.admitsWarmed("warm"))
        cache.recordWarmed(snapshot("warm"), session: nil)
        #expect(cache.presentation(threadID: "warm") == nil)
        #expect(cache.presentation(threadID: "a") != nil && cache.presentation(threadID: "b") != nil)

        var roomy = RecentConversationCache(capacity: 2)
        roomy.record(snapshot("a"), session: nil)
        roomy.recordWarmed(snapshot("warm"), session: nil)
        roomy.record(snapshot("b"), session: nil)
        #expect(roomy.presentation(threadID: "warm") == nil)
        #expect(roomy.presentation(threadID: "a") != nil && roomy.presentation(threadID: "b") != nil)
    }

    @Test func draftsAndEmptyConversationsAreNotRemembered() {
        var cache = RecentConversationCache(capacity: 1)
        cache.record(snapshot("kept"), session: nil)
        cache.record(snapshot(nil), session: nil)
        cache.record(ConversationSnapshot(conversationID: UUID(), ownerID: UUID(), threadID: "empty", revision: 1,
            messages: [], timelines: [], items: [], lastTurnCompletedAt: nil), session: nil)
        #expect(cache.presentation(threadID: "kept") != nil)
        #expect(cache.presentation(threadID: "empty") == nil)
    }

    @Test func memoryPressureKeepsOnlyTheVisibleConversation() {
        var cache = RecentConversationCache(capacity: 4)
        cache.record(snapshot("visible"), session: nil)
        cache.record(snapshot("hidden"), session: nil)
        cache.removeAll(keeping: ["visible"])
        #expect(cache.presentation(threadID: "visible") != nil)
        #expect(cache.presentation(threadID: "hidden") == nil)
        cache.record(snapshot("next"), session: nil)
        cache.record(snapshot("after"), session: nil)
        cache.record(snapshot("last"), session: nil)
        cache.record(snapshot("overflow"), session: nil)
        #expect(cache.presentation(threadID: "visible") == nil)
    }
}
