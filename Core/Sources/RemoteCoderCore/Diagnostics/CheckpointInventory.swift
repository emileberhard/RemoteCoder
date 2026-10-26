import Foundation

struct CheckpointInventory: Encodable, Sendable {
    static let entryLimit = 128
    static let byteLimit = 128 * 1_024

    struct Contents: Encodable, Sendable {
        let threadID: String?
        let historyItemCount: Int
        let historyTurnCount: Int
        let turnCount: Int
        let itemCount: Int
        var attachmentCount: Int? = nil
        var attachmentBytes: [Int]? = nil

        init(_ checkpoint: ConversationState.Checkpoint) {
            threadID = checkpoint.threadID
            historyItemCount = checkpoint.historyWindow?.items.count ?? 0
            historyTurnCount = checkpoint.historyWindow?.metadata.count ?? 0
            turnCount = checkpoint.turns.count
            itemCount = checkpoint.turns.values.reduce(0) { $0 + $1.items.count }
        }
    }

    struct Entry: Encodable, Sendable {
        let conversationID: UUID
        let protected: Bool?
        let retained: Bool
        let invalidation: String?
        let primaryPayloadBytes: Int
        let cacheBytes: Int
        let physicalFileBytes: Int
        let contents: Contents?
    }

    struct Totals: Encodable, Sendable {
        var records = 0
        var protectedRecords = 0
        var unknownProtectionRecords = 0
        var primaryPayloadBytes = 0
        var cacheBytes = 0
        var physicalFileBytes = 0
        var recordsWithKnownContents = 0
        var historyItemCount: Int? = 0
        var historyTurnCount: Int? = 0
        var turnCount: Int? = 0
        var itemCount: Int? = 0
        var attachmentCount: Int? = nil
        var attachmentBytes: Int? = nil

        mutating func include(_ entry: Entry) {
            records += 1
            if entry.protected == true { protectedRecords += 1 }
            if entry.protected == nil { unknownProtectionRecords += 1 }
            primaryPayloadBytes += entry.primaryPayloadBytes
            cacheBytes += entry.cacheBytes
            physicalFileBytes += entry.physicalFileBytes
            if let contents = entry.contents {
                recordsWithKnownContents += 1
                historyItemCount = historyItemCount.map { $0 + contents.historyItemCount }
                historyTurnCount = historyTurnCount.map { $0 + contents.historyTurnCount }
                turnCount = turnCount.map { $0 + contents.turnCount }
                itemCount = itemCount.map { $0 + contents.itemCount }
            } else {
                historyItemCount = nil
                historyTurnCount = nil
                turnCount = nil
                itemCount = nil
            }
        }
    }

    let hostID: UUID
    let cacheBudgetBytes: Int
    let primaryBudgetBytes: Int
    var totals = Totals()
    private(set) var entries: [Entry] = []
    private(set) var droppedRecords = 0
    private var entryBytes = 0

    init(hostID: UUID, cacheBudgetBytes: Int, primaryBudgetBytes: Int) {
        self.hostID = hostID
        self.cacheBudgetBytes = cacheBudgetBytes
        self.primaryBudgetBytes = primaryBudgetBytes
    }

    mutating func include(_ entry: Entry) {
        totals.include(entry)
        guard entries.count < Self.entryLimit,
              let bytes = try? JSONEncoder().encode(entry).count,
              entryBytes + bytes < Self.byteLimit - 2_048 else {
            droppedRecords += 1
            return
        }
        entryBytes += bytes
        entries.append(entry)
    }

    private enum CodingKeys: String, CodingKey {
        case hostID, cacheBudgetBytes, primaryBudgetBytes, totals, entries, droppedRecords
    }
}
