import Foundation
import Testing
@testable import RemoteCoderCore

struct ConversationHeaderOwnerTests {
    @Test func retiredHeaderWritesCannotOverwriteAReplacementTarget() async throws {
        let temporary = TemporaryHostStorage()
        defer { temporary.cleanUp() }
        let target = ExecutionTarget(hostID: UUID())
        let oldOwner = ConversationHeaderStore.scoped(to: target, storage: temporary.storage)
        var header = try ThreadFixture.basic("kept", updatedAt: 1)
        header.name = "Old name"
        await oldOwner.save(snapshot: .init(threads: [header], lastSuccessfulRefreshAt: nil, revision: 1))
        await oldOwner.retire()
        let replacement = ConversationHeaderStore.scoped(to: target, storage: temporary.storage)
        #expect(await replacement.load().revision == 1)
        header.name = "Current name"
        let current = ConversationHeaderStore.Snapshot(threads: [header], lastSuccessfulRefreshAt: nil, revision: 2)
        await replacement.save(snapshot: current)
        header.name = "Late predecessor name"
        await oldOwner.save(snapshot: .init(threads: [header], lastSuccessfulRefreshAt: nil, revision: 3))
        #expect(await replacement.load() == current)
        #expect(await ConversationHeaderStore.scoped(to: target, storage: temporary.storage).load() == current)
    }

    @Test func aRemovedTargetReleasesItsHeaderStoreRatherThanRetainingAllHostKeys() {
        weak var retiredOwner: ConversationHeaderStore?
        do {
            let first = ConversationHeaderStore.scoped(to: .init(hostID: UUID()), storage: .live)
            let second = ConversationHeaderStore.scoped(to: .init(hostID: UUID()), storage: .live)
            #expect(first !== second)
            retiredOwner = first
        }
        #expect(retiredOwner == nil)
    }
}
