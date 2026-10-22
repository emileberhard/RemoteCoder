@testable import RemoteCoderCore

actor RecordingContentSubscriptions: ConversationContentSubscriptions {
    private(set) var threadIDs: Set<String> = []
    private(set) var revision: UInt64 = 0

    func replaceContentSubscriptions(threadIDs: Set<String>, revision: UInt64) {
        guard revision > self.revision else { return }
        self.revision = revision
        self.threadIDs = threadIDs
    }
}
