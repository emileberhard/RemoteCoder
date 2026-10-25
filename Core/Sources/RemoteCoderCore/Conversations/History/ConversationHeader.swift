import Foundation

enum ConversationAgentClassification: Codable, Equatable, Sendable {
    case unresolved
    case root
    case child(ConversationAgentRelation)

    var isDefinitive: Bool {
        if case .unresolved = self { return false }
        return true
    }

    var relation: ConversationAgentRelation? {
        if case let .child(relation) = self { return relation }
        return nil
    }
}

struct ConversationHeader: Codable, Identifiable, Equatable, Sendable {
    static let previewCharacterLimit = 512

    let id: String
    let preview: String
    var name: String?
    var model: String?
    var modelProvider: String?
    var reasoningEffort: CodexAppServerV2.ReasoningEffort?
    var extra: CodexAppServerV2.ThreadExtra?
    let createdAt: Int64
    let updatedAt: Int64
    var lastTurnCompletedAt: Int64?
    var recencyAt: Int64?
    let path: String?
    let cwd: String
    let status: CodexAppServerV2.ThreadStatus
    private(set) var spawnedAsSubAgent: Bool
    var nativeParentThreadID: String?
    var canAcceptDirectInput: Bool?
    var agentClassification: ConversationAgentClassification
    var agentRelation: ConversationAgentRelation? {
        get { agentClassification.relation }
        set { agentClassification = newValue.map(ConversationAgentClassification.child) ?? .unresolved }
    }
    var pendingHistorySince: Date?

    init(_ thread: CodexAppServerV2.Thread) {
        let spawn = thread.source.objectValue?["subAgent"]?.objectValue?["thread_spawn"]?.objectValue
        id = thread.id
        preview = String(thread.previewContent.displayText.prefix(Self.previewCharacterLimit))
        name = thread.name
        model = thread.model
        modelProvider = thread.modelProvider
        reasoningEffort = thread.reasoningEffort
        extra = thread.extra
        createdAt = thread.createdAt
        updatedAt = thread.updatedAt
        lastTurnCompletedAt = thread.lastTurnCompletedAt
        recencyAt = thread.recencyAt
        path = thread.path
        cwd = thread.cwd
        status = thread.status
        spawnedAsSubAgent = spawn != nil
        nativeParentThreadID = thread.parentThreadId ?? spawn?["parent_thread_id"]?.stringValue
        canAcceptDirectInput = thread.canAcceptDirectInput
        agentClassification = thread.agentRelation.map(ConversationAgentClassification.child) ?? .unresolved
    }

    private enum CodingKeys: String, CodingKey {
        case id, preview, name, model, modelProvider, reasoningEffort, extra, createdAt, updatedAt, lastTurnCompletedAt, recencyAt
        case path, cwd, status, spawnedAsSubAgent, nativeParentThreadID, canAcceptDirectInput, agentRelation
        case agentClassification, pendingHistorySince
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        preview = String(try values.decode(String.self, forKey: .preview).prefix(Self.previewCharacterLimit))
        name = try values.decodeIfPresent(String.self, forKey: .name)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        modelProvider = try values.decodeIfPresent(String.self, forKey: .modelProvider)
        reasoningEffort = try values.decodeIfPresent(CodexAppServerV2.ReasoningEffort.self, forKey: .reasoningEffort)
        extra = try values.decodeIfPresent(CodexAppServerV2.ThreadExtra.self, forKey: .extra)
        createdAt = try values.decode(Int64.self, forKey: .createdAt)
        updatedAt = try values.decode(Int64.self, forKey: .updatedAt)
        lastTurnCompletedAt = try values.decodeIfPresent(Int64.self, forKey: .lastTurnCompletedAt)
        recencyAt = try values.decodeIfPresent(Int64.self, forKey: .recencyAt)
        path = try values.decodeIfPresent(String.self, forKey: .path)
        cwd = try values.decode(String.self, forKey: .cwd)
        status = try values.decode(CodexAppServerV2.ThreadStatus.self, forKey: .status)
        spawnedAsSubAgent = try values.decode(Bool.self, forKey: .spawnedAsSubAgent)
        nativeParentThreadID = try values.decodeIfPresent(String.self, forKey: .nativeParentThreadID)
        canAcceptDirectInput = try values.decodeIfPresent(Bool.self, forKey: .canAcceptDirectInput)
        let legacyRelation = try values.decodeIfPresent(ConversationAgentRelation.self, forKey: .agentRelation)
        agentClassification = try values.decodeIfPresent(ConversationAgentClassification.self, forKey: .agentClassification)
            ?? legacyRelation.map(ConversationAgentClassification.child) ?? .unresolved
        pendingHistorySince = try values.decodeIfPresent(Date.self, forKey: .pendingHistorySince)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(preview, forKey: .preview)
        try values.encodeIfPresent(name, forKey: .name)
        try values.encodeIfPresent(model, forKey: .model)
        try values.encodeIfPresent(modelProvider, forKey: .modelProvider)
        try values.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try values.encodeIfPresent(extra, forKey: .extra)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encodeIfPresent(lastTurnCompletedAt, forKey: .lastTurnCompletedAt)
        try values.encodeIfPresent(recencyAt, forKey: .recencyAt)
        try values.encodeIfPresent(path, forKey: .path)
        try values.encode(cwd, forKey: .cwd)
        try values.encode(status, forKey: .status)
        try values.encode(spawnedAsSubAgent, forKey: .spawnedAsSubAgent)
        try values.encodeIfPresent(nativeParentThreadID, forKey: .nativeParentThreadID)
        try values.encodeIfPresent(canAcceptDirectInput, forKey: .canAcceptDirectInput)
        try values.encodeIfPresent(agentRelation, forKey: .agentRelation)
        try values.encode(agentClassification, forKey: .agentClassification)
        try values.encodeIfPresent(pendingHistorySince, forKey: .pendingHistorySince)
    }

    @concurrent static func prepare(_ thread: CodexAppServerV2.Thread) async -> Self {
        Self(thread)
    }

    mutating func retainAncestry(from previous: Self) {
        precondition(id == previous.id)
        if !agentClassification.isDefinitive { agentClassification = previous.agentClassification }
        nativeParentThreadID = nativeParentThreadID ?? previous.nativeParentThreadID
        spawnedAsSubAgent = spawnedAsSubAgent || previous.spawnedAsSubAgent
        canAcceptDirectInput = canAcceptDirectInput ?? previous.canAcceptDirectInput
    }

    var sidebarTimestamp: Int64 { lastTurnCompletedAt ?? createdAt }

    var latestActivityAt: Int64 { max(recencyAt ?? createdAt, sidebarTimestamp) }

    var isNativeAgent: Bool { nativeParentThreadID != nil || spawnedAsSubAgent }

    var isDelegatedAgent: Bool { isNativeAgent || agentRelation != nil }

    var agentParentThreadID: String? { nativeParentThreadID ?? agentRelation?.parentThreadId }

    var acceptsDirectInput: Bool { !isNativeAgent && canAcceptDirectInput != false }

    var displayTitle: String {
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        let text = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "(untitled)" : text
    }
}
