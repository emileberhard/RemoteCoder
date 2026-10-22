import Foundation

enum ConversationPurpose: String, Codable, Sendable {
    case probe
    case automation
}

enum ConversationSettlement: Codable, Equatable, Sendable {
    case settled(through: Int64)
    case active(through: Int64)

    static let automaticAfter: Int64 = 3 * 86_400

    private enum CodingKeys: String, CodingKey { case state, through }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let through = try container.decode(Int64.self, forKey: .through)
        switch try container.decode(String.self, forKey: .state) {
        case "settled": self = .settled(through: through)
        case "active": self = .active(through: through)
        case let state:
            throw DecodingError.dataCorruptedError(forKey: .state, in: container, debugDescription: "unknown settlement \(state)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .settled(through):
            try container.encode("settled", forKey: .state)
            try container.encode(through, forKey: .through)
        case let .active(through):
            try container.encode("active", forKey: .state)
            try container.encode(through, forKey: .through)
        }
    }
}

struct ThreadMarks: Codable, Equatable, Sendable {
    var revision: UInt64
    var seenThrough: Int64?
    var markedUnread: Bool
    var pinName: String?
    var purpose: ConversationPurpose?
    var settlement: ConversationSettlement?
    var doneThrough: Int64?

    init(revision: UInt64 = 0, seenThrough: Int64? = nil, markedUnread: Bool = false, pinName: String? = nil,
         purpose: ConversationPurpose? = nil, settlement: ConversationSettlement? = nil, doneThrough: Int64? = nil) {
        self.revision = revision
        self.seenThrough = seenThrough
        self.markedUnread = markedUnread
        self.pinName = pinName
        self.purpose = purpose
        self.settlement = settlement
        self.doneThrough = doneThrough
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decode(UInt64.self, forKey: .revision)
        seenThrough = try container.decodeIfPresent(Int64.self, forKey: .seenThrough)
        markedUnread = try container.decodeIfPresent(Bool.self, forKey: .markedUnread) ?? false
        pinName = try container.decodeIfPresent(String.self, forKey: .pinName)
        purpose = try container.decodeIfPresent(ConversationPurpose.self, forKey: .purpose)
        settlement = try container.decodeIfPresent(ConversationSettlement.self, forKey: .settlement)
        doneThrough = try container.decodeIfPresent(Int64.self, forKey: .doneThrough)
    }

    var isEmpty: Bool {
        seenThrough == nil && !markedUnread && pinName == nil && purpose == nil && settlement == nil && doneThrough == nil
    }
}

enum ConversationPinName {
    static let maximumBytes = 256

    static func clamped(_ text: String) -> String {
        guard text.utf8.count > maximumBytes else { return text }
        var clamped = ""
        var bytes = 0
        for character in text {
            bytes += character.utf8.count
            guard bytes <= maximumBytes else { break }
            clamped.append(character)
        }
        return clamped
    }

    static func normalized(_ text: String) -> String? {
        let name = clamped(text.trimmingCharacters(in: .whitespacesAndNewlines))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

enum ConversationMarkChange: Codable, Equatable, Sendable {
    case markRead(threadID: String, through: Int64)
    case markUnread(threadID: String)
    case markAllRead(through: Int64)
    case markRetiredScopeRead(scopeID: String, through: Int64)
    case pin(threadID: String, name: String)
    case unpin(threadID: String)
    case setPurpose(threadID: String, purpose: ConversationPurpose)
    case settle(threadID: String, through: Int64)
    case unsettle(threadID: String, through: Int64)

    private enum CodingKeys: String, CodingKey { case op, threadId, scopeId, through, name, purpose }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let thread = { try container.decode(String.self, forKey: .threadId) }
        switch try container.decode(String.self, forKey: .op) {
        case "markRead": self = .markRead(threadID: try thread(), through: try container.decode(Int64.self, forKey: .through))
        case "markUnread": self = .markUnread(threadID: try thread())
        case "markAllRead": self = .markAllRead(through: try container.decode(Int64.self, forKey: .through))
        case "markRetiredScopeRead": self = .markRetiredScopeRead(scopeID: try container.decode(String.self, forKey: .scopeId),
            through: try container.decode(Int64.self, forKey: .through))
        case "pin": self = .pin(threadID: try thread(), name: try container.decode(String.self, forKey: .name))
        case "unpin": self = .unpin(threadID: try thread())
        case "setPurpose":
            self = .setPurpose(threadID: try thread(), purpose: try container.decode(ConversationPurpose.self, forKey: .purpose))
        case "settle": self = .settle(threadID: try thread(), through: try container.decode(Int64.self, forKey: .through))
        case "unsettle": self = .unsettle(threadID: try thread(), through: try container.decode(Int64.self, forKey: .through))
        case let op:
            throw DecodingError.dataCorruptedError(forKey: .op, in: container, debugDescription: "unknown mark change \(op)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .markRead(threadID, through):
            try container.encode("markRead", forKey: .op)
            try container.encode(threadID, forKey: .threadId)
            try container.encode(through, forKey: .through)
        case let .markUnread(threadID):
            try container.encode("markUnread", forKey: .op)
            try container.encode(threadID, forKey: .threadId)
        case let .markAllRead(through):
            try container.encode("markAllRead", forKey: .op)
            try container.encode(through, forKey: .through)
        case let .markRetiredScopeRead(scopeID, through):
            try container.encode("markRetiredScopeRead", forKey: .op)
            try container.encode(scopeID, forKey: .scopeId)
            try container.encode(through, forKey: .through)
        case let .pin(threadID, name):
            try container.encode("pin", forKey: .op)
            try container.encode(threadID, forKey: .threadId)
            try container.encode(name, forKey: .name)
        case let .unpin(threadID):
            try container.encode("unpin", forKey: .op)
            try container.encode(threadID, forKey: .threadId)
        case let .setPurpose(threadID, purpose):
            try container.encode("setPurpose", forKey: .op)
            try container.encode(threadID, forKey: .threadId)
            try container.encode(purpose, forKey: .purpose)
        case let .settle(threadID, through):
            try container.encode("settle", forKey: .op)
            try container.encode(threadID, forKey: .threadId)
            try container.encode(through, forKey: .through)
        case let .unsettle(threadID, through):
            try container.encode("unsettle", forKey: .op)
            try container.encode(threadID, forKey: .threadId)
            try container.encode(through, forKey: .through)
        }
    }
}

struct ConversationMarks: Codable, Equatable, Sendable {
    static let settlementSchemaVersion = 2

    var schemaVersion: Int
    var revision: UInt64
    var readBaseline: Int64
    var threads: [String: ThreadMarks]
    var supportsRetiredScopeRead: Bool? = nil

    private enum CodingKeys: String, CodingKey { case schemaVersion, revision, readBaseline, threads, supportsRetiredScopeRead }

    var offersSettlement: Bool { schemaVersion >= Self.settlementSchemaVersion }

    func marks(for threadID: String) -> ThreadMarks? { threads[threadID].flatMap { $0.isEmpty ? nil : $0 } }

    func pinName(for threadID: String) -> String? { threads[threadID]?.pinName }

    var pinNames: [String: String] { threads.compactMapValues(\.pinName) }

    func purpose(of threadID: String) -> ConversationPurpose? { threads[threadID]?.purpose }

    func settlement(of threadID: String) -> ConversationSettlement? { threads[threadID]?.settlement }

    func isProbablyDone(_ thread: ConversationHeader) -> Bool {
        guard let marks = threads[thread.id], marks.purpose == nil, marks.pinName == nil,
              let doneThrough = marks.doneThrough else { return false }
        return thread.latestActivityAt <= doneThrough
    }

    func isUnread(_ thread: ConversationHeader) -> Bool {
        let marks = threads[thread.id]
        if marks?.markedUnread == true { return true }
        guard marks?.purpose == nil, let completedAt = thread.lastTurnCompletedAt else { return false }
        return completedAt > max(readBaseline, marks?.seenThrough ?? .min)
    }

    func isUnseenQuestion(askedAtMs: Int64, in threadID: String) -> Bool {
        askedAtMs / 1000 > max(readBaseline, threads[threadID]?.seenThrough ?? .min)
    }

    func coversRequest(madeAt requestAt: Int64?, in thread: ConversationHeader, at now: Int64) -> Bool {
        guard offersSettlement else { return false }
        let automaticThrough = now - ConversationSettlement.automaticAfter
        switch threads[thread.id]?.settlement {
        case let .settled(through):
            guard let requestAt else { return thread.latestActivityAt <= through }
            return requestAt <= max(through, automaticThrough)
        case let .active(through) where thread.latestActivityAt <= through:
            return false
        default:
            return requestAt.map { $0 <= automaticThrough } ?? false
        }
    }

    func isSettled(_ thread: ConversationHeader, isLive: Bool, at now: Int64) -> Bool {
        guard offersSettlement, !isLive else { return false }
        let marks = threads[thread.id]
        guard marks?.pinName == nil, !isUnread(thread) else { return false }
        switch marks?.settlement {
        case let .settled(through) where marks?.purpose != nil || thread.latestActivityAt <= through:
            return true
        case let .active(through) where thread.latestActivityAt <= through:
            return false
        default:
            return thread.latestActivityAt <= now - ConversationSettlement.automaticAfter
        }
    }

    mutating func apply(_ delta: ConversationMarks) {
        schemaVersion = max(schemaVersion, delta.schemaVersion)
        revision = max(revision, delta.revision)
        readBaseline = max(readBaseline, delta.readBaseline)
        for (threadID, incoming) in delta.threads where incoming.revision >= (threads[threadID]?.revision ?? 0) {
            threads[threadID] = incoming
        }
        for (threadID, marks) in threads where marks.seenThrough.map({ $0 <= readBaseline }) == true {
            threads[threadID]?.seenThrough = nil
        }
    }

    func applying(_ change: ConversationMarkChange) -> ConversationMarks {
        var next = self
        func update(_ threadID: String, _ edit: (inout ThreadMarks) -> Void) {
            var marks = next.threads[threadID] ?? ThreadMarks()
            edit(&marks)
            if let seen = marks.seenThrough, seen <= next.readBaseline { marks.seenThrough = nil }
            next.threads[threadID] = marks.isEmpty ? next.threads[threadID].map { ThreadMarks(revision: $0.revision) } : marks
        }
        switch change {
        case let .markRead(threadID, through):
            update(threadID) { marks in
                marks.markedUnread = false
                if through > (marks.seenThrough ?? .min) { marks.seenThrough = through }
            }
        case let .markUnread(threadID):
            update(threadID) { $0.markedUnread = true }
        case let .markAllRead(through):
            next.readBaseline = max(next.readBaseline, through)
            for threadID in next.threads.keys { update(threadID) { $0.markedUnread = false } }
        case .markRetiredScopeRead:
            break
        case let .pin(threadID, name):
            update(threadID) { $0.pinName = ConversationPinName.normalized(name) }
        case let .unpin(threadID):
            update(threadID) { $0.pinName = nil }
        case let .setPurpose(threadID, purpose):
            update(threadID) { $0.purpose = purpose }
        case let .settle(threadID, through):
            update(threadID) { marks in
                marks.markedUnread = false
                if through > (marks.seenThrough ?? .min) { marks.seenThrough = through }
                marks.pinName = nil
                marks.settlement = .settled(through: through)
            }
        case let .unsettle(threadID, through):
            update(threadID) {
                $0.settlement = .active(through: through)
                $0.doneThrough = nil
            }
        }
        return next
    }
}

extension ConversationMarks {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        revision = try container.decode(UInt64.self, forKey: .revision)
        readBaseline = try container.decode(Int64.self, forKey: .readBaseline)
        threads = try container.decode([String: ThreadMarks].self, forKey: .threads)
        supportsRetiredScopeRead = try container.decodeIfPresent(Bool.self, forKey: .supportsRetiredScopeRead)
    }
}

struct ConversationSettlementEdit: Equatable, Sendable {
    let threadID: String
    let changes: [ConversationMarkChange]
}

extension ConversationMarks {
    func settling(_ headers: [ConversationHeader], newestRequestAt: [String: Int64])
        -> (edits: [ConversationSettlementEdit], undo: [ConversationSettlementEdit]) {
        guard offersSettlement else { return ([], []) }
        let settled = headers.filter { !$0.isDelegatedAgent }
        let edits = settled.map { header in
            let through = max(header.latestActivityAt, newestRequestAt[header.id] ?? .min)
            return ConversationSettlementEdit(threadID: header.id, changes: [.settle(threadID: header.id, through: through)])
        }
        let undo = settled.map { header -> ConversationSettlementEdit in
            var changes: [ConversationMarkChange] = [.unsettle(threadID: header.id, through: header.latestActivityAt)]
            if let name = pinName(for: header.id) { changes.append(.pin(threadID: header.id, name: name)) }
            if isUnread(header) { changes.append(.markUnread(threadID: header.id)) }
            return ConversationSettlementEdit(threadID: header.id, changes: changes)
        }
        return (edits, undo)
    }

    func unsettling(_ headers: [ConversationHeader]) -> [ConversationSettlementEdit] {
        guard offersSettlement else { return [] }
        return headers.filter { !$0.isDelegatedAgent }.map { header in
            ConversationSettlementEdit(threadID: header.id, changes: [.unsettle(threadID: header.id, through: header.latestActivityAt)])
        }
    }
}

struct ConversationMarksReplica: Codable, Equatable, Sendable {
    struct Pending: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let change: ConversationMarkChange
    }

    static let pendingLimit = 2_000
    static let batchLimit = 500

    private(set) var acknowledged: ConversationMarks?
    private(set) var pending: [Pending] = []
    private var requiresRetirementRead: Bool?
    private var defaultScopeRetired: Bool?

    init(acknowledged: ConversationMarks? = nil, pending: [Pending] = []) {
        self.acknowledged = acknowledged
        self.pending = pending
    }

    var effective: ConversationMarks {
        let base = acknowledged ?? ConversationMarks(schemaVersion: 1, revision: 0, readBaseline: .max, threads: [:])
        return pending.reduce(base) { $0.applying($1.change) }
    }

    var isReadStateKnown: Bool { acknowledged != nil && requiresRetirementRead != true }

    mutating func retireDefaultScope() {
        guard defaultScopeRetired != true else { return }
        if acknowledged != nil || !pending.isEmpty { invalidateReadCoverage() }
        pending = Self.retiringGlobals(in: pending, scopeID: "default")
        defaultScopeRetired = true
    }

    private mutating func invalidateReadCoverage() {
        requiresRetirementRead = true
        acknowledged?.readBaseline = .max
        for thread in acknowledged?.threads.keys.map({ $0 }) ?? [] {
            acknowledged?.threads[thread]?.seenThrough = nil
            acknowledged?.threads[thread]?.markedUnread = false
        }
    }

    private static func retiringGlobals(in changes: [Pending], scopeID: String) -> [Pending] {
        changes.map { entry in
            guard case let .markAllRead(through) = entry.change else { return entry }
            return Pending(id: entry.id, change: .markRetiredScopeRead(scopeID: scopeID, through: through))
        }
    }

    mutating func record(_ change: ConversationMarkChange) {
        if case .markAllRead = change {
            pending.removeAll { if case .markAllRead = $0.change { true } else { false } }
        }
        pending.append(Pending(id: UUID(), change: change))
        evictOldestPending()
    }

    mutating func restore(_ stored: ConversationMarksReplica) {
        acknowledged = stored.acknowledged
        requiresRetirementRead = stored.requiresRetirementRead
        defaultScopeRetired = stored.defaultScopeRetired
        var restoredIDs: Set<UUID> = []
        pending = (stored.pending + pending).filter { restoredIDs.insert($0.id).inserted }
        evictOldestPending()
    }

    enum AdoptionFailure: LocalizedError {
        case pendingCapacity
        var errorDescription: String? { "Saved read and pin changes exceed the pending-change limit. Source data has been retained." }
    }

    mutating func adopt(_ other: ConversationMarksReplica, sourceID: UUID) throws {
        try prependPending(Self.retiringGlobals(in: other.pending, scopeID: sourceID.uuidString.lowercased()))
        if let cached = other.acknowledged {
            let metadata = cached.threads.mapValues { saved in
                var value = saved
                value.revision = 0
                value.seenThrough = nil
                value.markedUnread = false
                return value
            }
            if acknowledged == nil {
                acknowledged = ConversationMarks(schemaVersion: cached.schemaVersion, revision: 0, readBaseline: cached.readBaseline, threads: metadata)
            } else { acknowledged?.threads.merge(metadata) { existing, _ in existing } }
        }
        invalidateReadCoverage()
    }

    mutating func prependPending(_ changes: [Pending]) throws {
        var known = Set(pending.map(\.id))
        let merged = changes.filter { known.insert($0.id).inserted } + pending
        guard merged.count <= Self.pendingLimit else { throw AdoptionFailure.pendingCapacity }
        pending = merged
    }

    private mutating func evictOldestPending() {
        if pending.count > Self.pendingLimit { pending.removeFirst(pending.count - Self.pendingLimit) }
    }

    mutating func replaceAcknowledged(_ marks: ConversationMarks) {
        guard requiresRetirementRead != true || marks.supportsRetiredScopeRead == true else { return }
        acknowledged = marks
        requiresRetirementRead = nil
        guard !marks.offersSettlement else { return }
        pending.removeAll { entry in
            switch entry.change {
            case .settle, .unsettle: true
            default: false
            }
        }
    }

    mutating func acknowledge(_ sent: [Pending], delta: ConversationMarks?) {
        let sentIDs = Set(sent.map(\.id))
        pending.removeAll { sentIDs.contains($0.id) }
        if let delta { acknowledged?.apply(delta) }
    }

    mutating func receive(_ delta: ConversationMarks) {
        guard requiresRetirementRead != true else { return }
        acknowledged?.apply(delta)
    }
}
