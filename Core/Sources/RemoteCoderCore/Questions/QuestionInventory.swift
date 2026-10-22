import Foundation

struct QuestionVersion: Hashable, Sendable {
    let epoch: String
    let revision: UInt64
}

struct QuestionRecord: Codable, Hashable, Sendable, Identifiable {
    struct Answer: Codable, Hashable, Sendable {
        let text: String
        let itemId: String
        let clientId: String?
        let ordinal: Int64
        let atMs: Int64?
    }

    struct Slot: Codable, Hashable, Sendable {
        enum Resolution: String, Codable, Sendable { case pending, answered, dismissed, superseded }
        let index: Int
        let title: String
        let options: [String]
        let resolution: Resolution
        let answer: Answer?
    }

    let itemId: String
    let turnId: String
    let ordinal: Int64
    let askedAtMs: Int64?
    let revision: UInt64
    let questions: [Slot]

    var id: String { itemId }
    var isPending: Bool { questions.contains { $0.resolution == .pending } }
}

struct QuestionHostSnapshot: Codable, Hashable, Sendable {
    enum Coverage: String, Codable, Sendable { case ready, catchingUp, unavailable }
    let threadId: String
    let epoch: String
    let revision: UInt64
    let coverage: Coverage
    let reason: String?
    let records: [QuestionRecord]
    let pendingItemIds: [String]?
    let missingItemIds: [String]

    func validate() throws {
        guard !threadId.isEmpty, (coverage == .ready) == (pendingItemIds != nil),
              coverage != .ready || !epoch.isEmpty,
              Set(records.map(\.itemId)).count == records.count,
              pendingItemIds.map({ Set($0).count == $0.count }) != false
        else { throw GatewayClient.ClientError.invalidMessage }
        for record in records {
            guard !record.itemId.isEmpty, !record.turnId.isEmpty, !record.questions.isEmpty,
                  record.questions.count <= 128, record.revision <= revision,
                  record.questions.enumerated().allSatisfy({ $0.offset == $0.element.index && !$0.element.title.isEmpty
                      && ($0.element.resolution == .answered) == ($0.element.answer != nil) })
            else { throw GatewayClient.ClientError.invalidMessage }
        }
        if let pendingItemIds {
            guard Set(pendingItemIds) == Set(records.filter(\.isPending).map(\.itemId)),
                  Set(missingItemIds).isDisjoint(with: records.map(\.itemId))
            else { throw GatewayClient.ClientError.invalidMessage }
        }
    }
}

/// A replica of host facts. Sparse historical records merge independently of the
/// complete pending inventory. No transcript scan can manufacture pending state.
struct QuestionInventory: Codable, Hashable, Sendable {
    private(set) var epoch: String?
    private(set) var revision: UInt64 = 0
    private(set) var coverage: QuestionHostSnapshot.Coverage = .unavailable
    private(set) var reason: String?
    private(set) var records: [String: QuestionRecord] = [:]
    private(set) var pendingItemIDs: Set<String>?

    mutating func merge(_ incoming: QuestionHostSnapshot) throws {
        try incoming.validate()
        guard !incoming.epoch.isEmpty else { invalidate(incoming.reason); return }
        if epoch == incoming.epoch, revision > incoming.revision { return }
        if epoch != incoming.epoch { records.removeAll(); pendingItemIDs = nil }
        epoch = incoming.epoch
        revision = incoming.revision
        coverage = incoming.coverage
        reason = incoming.reason
        for record in incoming.records where records[record.itemId].map({ $0.revision <= record.revision }) ?? true {
            records[record.itemId] = record
        }
        for id in incoming.missingItemIds { records.removeValue(forKey: id) }
        pendingItemIDs = incoming.pendingItemIds.map(Set.init)
        let historical = records.values.filter { pendingItemIDs?.contains($0.itemId) != true }.sorted { $0.ordinal > $1.ordinal }
        for record in historical.dropFirst(128) { records.removeValue(forKey: record.itemId) }
    }

    mutating func invalidate(_ reason: String?) {
        coverage = .unavailable
        self.reason = reason
        pendingItemIDs = nil
    }

    func isActionable(_ record: QuestionRecord) -> Bool {
        coverage == .ready && pendingItemIDs?.contains(record.itemId) == true && record.isPending
    }
}

struct QuestionReadQuery: Encodable, Sendable {
    let threadId: String
    let itemIds: [String]
}

struct QuestionDismissal: Codable, Sendable {
    let threadId: String
    let itemId: String
    let expectedRecordRevision: UInt64
    let expectedEpoch: String
    let mutationId: UUID
}

struct QuestionDismissalResult: Decodable, Sendable {
    enum Status: String, Decodable, Sendable { case applied, conflict }
    let status: Status
    let epoch: String
    let revision: UInt64
    let record: QuestionRecord
}

protocol QuestionRemote: Sendable {
    func readQuestions(_ queries: [QuestionReadQuery]) async throws -> [QuestionHostSnapshot]
    func dismissQuestion(_ request: QuestionDismissal) async throws -> QuestionDismissalResult
}
