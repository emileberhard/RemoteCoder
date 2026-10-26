import Foundation

struct CheckpointInventory: Encodable, Sendable {
    static let entryLimit = 128
    static let byteLimit = 128 * 1_024
    private static let payloadOverheadByteBound = 4_096

    struct Contents: Encodable, Sendable {
        let threadID: String?
        let historyItemCount: Int
        let historyTurnCount: Int
        let turnCount: Int
        let itemCount: Int

        init(_ checkpoint: ConversationState.Checkpoint) {
            threadID = checkpoint.threadID
            historyItemCount = checkpoint.historyWindow?.items.count ?? 0
            historyTurnCount = checkpoint.historyWindow?.metadata.count ?? 0
            turnCount = checkpoint.turns.count
            itemCount = checkpoint.turns.values.reduce(0) { $0 + $1.items.count }
        }

        private enum CodingKeys: String, CodingKey {
            case historyItemCount, historyTurnCount, turnCount, itemCount
        }
    }

    struct Entry: Encodable, Sendable {
        let conversationID: UUID
        let threadID: String?
        let protected: Bool?
        let retained: Bool
        let invalidation: String?
        let primaryPayloadBytes: Int
        let cacheBytes: Int
        let physicalFileBytes: Int
        let contents: Contents?
    }

    struct SizeDistributions: Encodable, Sendable {
        static let bucketUpperBoundsBytes = [0, 1_024, 16_384, 262_144, 1_048_576, 4_194_304, 16_777_216, 67_108_864, 268_435_456]

        struct Counts: Encodable, Sendable {
            var physicalFileBytes = Array(repeating: 0, count: SizeDistributions.bucketUpperBoundsBytes.count + 1)
            var primaryPayloadBytes = Array(repeating: 0, count: SizeDistributions.bucketUpperBoundsBytes.count + 1)

            mutating func include(_ entry: Entry) {
                let physical = SizeDistributions.bucketUpperBoundsBytes.firstIndex { entry.physicalFileBytes <= $0 }
                    ?? SizeDistributions.bucketUpperBoundsBytes.count
                let primary = SizeDistributions.bucketUpperBoundsBytes.firstIndex { entry.primaryPayloadBytes <= $0 }
                    ?? SizeDistributions.bucketUpperBoundsBytes.count
                physicalFileBytes[physical] += 1
                primaryPayloadBytes[primary] += 1
            }
        }

        let upperBoundsBytes = Self.bucketUpperBoundsBytes
        var protected = Counts()
        var unprotected = Counts()
        var unknownProtection = Counts()

        mutating func include(_ entry: Entry) {
            switch entry.protected {
            case true?: protected.include(entry)
            case false?: unprotected.include(entry)
            case nil: unknownProtection.include(entry)
            }
        }
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
        var sizeDistributions = SizeDistributions()

        mutating func include(_ entry: Entry) {
            records += 1
            sizeDistributions.include(entry)
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
              entryBytes + bytes < Self.byteLimit - Self.payloadOverheadByteBound else {
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
