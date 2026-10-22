import Foundation
#if canImport(RemoteCoderCore)
@testable import RemoteCoderCore
#else
@testable import RemoteCoder
#endif

extension CodexAppServerV2.Thread {
    static func historyFixture(id: String = "thread", updatedAt: Int64 = 2) -> Self {
        .init(id: id, preview: "Fixture", createdAt: 1, updatedAt: updatedAt,
            path: nil, cwd: "/tmp", source: .string("cli"), name: nil, status: .idle)
    }
}

extension ConversationHeader {
    static func historyFixture(id: String = "thread", updatedAt: Int64 = 2) -> Self {
        .init(.historyFixture(id: id, updatedAt: updatedAt))
    }
}

extension GatewayHistoryService.ConversationSnapshot {
    static func fixture(threadID: String = "thread", wire: [CodexAppServerV2.ThreadItemsListResponse.Entry],
                        turns: [CodexAppServerV2.Turn] = [], older: String? = nil, newer: String? = nil,
                        placement: HistoryWindow.Placement = .tail, base: HistoryWindow? = nil,
                        source: Source = .gateway, fetchedAt: Date = .now) -> Self {
        let metadataPlacement: HistoryRange<CodexAppServerV2.Turn>.Placement = placement == .reset ? .reset : .tail
        let update = HistoryWindow.Update(
            items: .init(elements: wire.reversed(), older: older, newer: newer, fetchedAt: fetchedAt),
            placement: placement,
            metadata: turns.isEmpty ? [] : [.init(page: .init(turns, next: nil, backwards: nil, direction: .desc,
                placement: metadataPlacement, fetchedAt: fetchedAt), placement: metadataPlacement)])
        var window = base ?? HistoryWindow()
        window.apply(update)
        return .init(header: .historyFixture(id: threadID), window: window, update: source == .storedTail ? nil : update,
            fetchedAt: fetchedAt, source: source)
    }
}

extension ConversationState {
    mutating func merge(_ snapshot: GatewayHistoryService.ConversationSnapshot) {
        let read = beginHistoryRead()
        merge(snapshot, read: read)
    }

    mutating func mergeObservation(header: ConversationHeader, checkpoint: CodexAppServerV2.ThreadObservationCheckpoint,
                                   history: GatewayHistoryService.ObservationHistory) {
        let read = beginHistoryRead()
        mergeObservation(header: header, checkpoint: checkpoint, history: history, read: read)
    }
}

extension ConversationSession {
    func merge(_ snapshot: GatewayHistoryService.ConversationSnapshot) async -> ConversationSnapshot {
        await merge(snapshot, read: beginHistoryRead())
    }
}

