import Foundation

protocol ConversationContentSubscriptions: Sendable {
    func replaceContentSubscriptions(threadIDs: Set<String>, revision: UInt64) async
}

nonisolated enum ConversationContentSubscriptionLimits {
    static let maximumThreads = 64
    static let maximumThreadIDBytes = 512
}
