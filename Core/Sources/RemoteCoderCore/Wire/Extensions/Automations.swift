import Foundation

/// The service owns validation and scheduling. Saved bodies are lossless, including
/// settings a newer service understands but this client does not yet expose.
struct AutomationDefinition: Codable, Equatable, Sendable {
    var fields: [String: JSONValue]
    init(fields: [String: JSONValue]) { self.fields = fields }
    init(from decoder: any Decoder) throws {
        fields = try decoder.singleValueContainer().decode([String: JSONValue].self)
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fields)
    }
    var id: String { fields["id"]?.stringValue ?? "" }
    var name: String { fields["name"]?.stringValue ?? id }
    var enabled: Bool { fields["enabled"] == .bool(true) }
    var isSource: Bool { id.hasPrefix("source/") }
    var agent: [String: JSONValue]? { fields["run"]?.objectValue?["agent"]?.objectValue }
    var triggers: [[String: JSONValue]] {
        if let array = fields["when"]?.arrayValue { return array.compactMap(\.objectValue) }
        return fields["when"]?.objectValue.map { [$0] } ?? []
    }
}

struct AutomationValidationField: Decodable, Equatable, Sendable {
    let path: [JSONValue]
    let message: String
    func presented(whenIsList: Bool) -> Self? {
        guard path.first == .string("when"), path.count > 1 else { return self }
        if path[1] == .string("Trigger") {
            guard !whenIsList else { return nil }
            return Self(path: [path[0]] + path.dropFirst(2), message: message)
        }
        if path[1] == .string("list[Trigger]") {
            guard whenIsList else { return nil }
            return Self(path: [path[0]] + path.dropFirst(2), message: message)
        }
        return self
    }
    var label: String {
        path.map { value in
            if let text = value.stringValue { return text }
            if case .number(let index) = value { return String(Int(index)) }
            return ""
        }.filter { !$0.isEmpty }.joined(separator: ".")
    }
}

struct AutomationServiceError: Decodable, LocalizedError, Sendable {
    let code: String
    let message: String
    let hint: String?
    let currentRevision: Int?
    let fields: [AutomationValidationField]?
    enum CodingKeys: String, CodingKey { case code, message, hint, fields; case currentRevision = "current_revision" }
    var errorDescription: String? { [message, hint].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n") }
    var isConflict: Bool { code == "conflict" }
}

struct AutomationEnvelope<Value: Decodable & Sendable>: Decodable, Sendable {
    let ok: Bool
    let data: Value?
    let health: JSONValue?
    let error: AutomationServiceError?
    func value() throws -> Value {
        if let error { throw error }
        guard ok, let data else { throw GatewayClient.ClientError.invalidMessage }
        return data
    }
}

struct AutomationStatus: Decodable, Sendable {
    struct Capabilities: Decodable, Sendable {
        let apiVersion: Int
        let historyVersion: Int
        enum CodingKeys: String, CodingKey { case apiVersion = "api_version", historyVersion = "history_version" }
    }
    let capabilities: Capabilities?
    let definitionAuthority: String?
    let historyCoverage: String?
    enum CodingKeys: String, CodingKey {
        case capabilities
        case definitionAuthority = "definition_authority", historyCoverage = "history_coverage"
    }
    var supportsManagement: Bool { capabilities?.apiVersion == 1 && capabilities?.historyVersion == 1 }
}

struct AutomationRequest: Encodable, Equatable, Sendable {
    var id: String?
    var data: [String: JSONValue]?
    var replaceDefinition: Bool?
    var requestId: String?
    var expectedRevision: Int?
    var targetRevision: Int?
    var includeRemoved: Bool?
    var state: String?
    var search: String?
    var limit: Int?
    var offset: Int?
    var runId: String?
    var cancel: Bool?
    var reason: String?
    var outputOffset: Int?
    var outputLimit: Int?
}

struct AutomationRunSummary: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let state: String
    let created: Double?
    let started: Double?
    let revision: Int?
    let finished: Double?
    let error: String?
    var isActive: Bool { ["queued", "running", "uncertain"].contains(state) }
}

struct AutomationSummary: Decodable, Identifiable, Sendable {
    let id: String
    let revision: Int
    let name: String?
    let enabled: Bool
    let removed: JSONValue?
    let completed: Bool?
    let when: JSONValue?
    let kind: String?
    let nextDue: Double?
    let lastRun: AutomationRunSummary?
    let expired: Bool?
    let managed: Bool?
    let nextDueTimezone: String?
    enum CodingKeys: String, CodingKey {
        case id, revision, name, enabled, removed, completed, when, kind, expired, managed
        case nextDue = "next_due", lastRun = "last_run", nextDueTimezone = "next_due_timezone"
    }
    var nextDueLabel: String? = nil
    var isRemoved: Bool { removed == .bool(true) || removed == .number(1) }
    var isSource: Bool { id.hasPrefix("source/") }
    var stateLabel: String {
        if isRemoved { return "Removed" }
        if expired == true { return "Expired" }
        if completed == true { return "Completed" }
        return enabled ? "Active" : "Paused"
    }
    var label: String { name ?? id }
    var triggerDescription: String { AutomationPresentation.triggerDescription(when) }
}

struct AutomationList: Decodable, Sendable {
    let items: [AutomationSummary]
    let limit: Int?
    let offset: Int?
}

struct AutomationDetail: Decodable, Sendable {
    let id: String
    let revision: Int
    let definition: AutomationDefinition
    let removed: JSONValue?
    let runs: [AutomationRunSummary]?
    let importedRuns: [JSONValue]?
    let revisionMetadata: AutomationRevision?
    let managed: Bool?
    let expired: Bool?
    let completed: JSONValue?
    enum CodingKeys: String, CodingKey {
        case id, revision, definition, removed, runs, managed, expired, completed
        case importedRuns = "imported_runs", revisionMetadata = "revision_metadata"
    }
    var isRemoved: Bool { removed == .bool(true) || removed == .number(1) }
}

struct AutomationRevision: Decodable, Identifiable, Sendable {
    let revision: Int
    let schemaVersion: Int
    let removed: Bool
    let changeKind: String
    let recordedAt: JSONValue
    let actor: JSONValue?
    let reason: String?
    let restoredFromRevision: Int?
    var id: Int { revision }
    enum CodingKeys: String, CodingKey {
        case revision, removed, actor, reason
        case schemaVersion = "schema_version", changeKind = "change_kind", recordedAt = "recorded_at"
        case restoredFromRevision = "restored_from_revision"
    }
}

struct AutomationHistory: Decodable, Sendable {
    let id: String
    let items: [AutomationRevision]
    let limit: Int
    let offset: Int
    let baselineRevision: Int?
    enum CodingKeys: String, CodingKey {
        case id, items, limit, offset
        case baselineRevision = "baseline_revision"
    }
}

struct AutomationRunDetail: Decodable, Sendable {
    let id: String
    let state: String
    let revision: Int?
    let definition: AutomationDefinition?
    let receipt: JSONValue?
    let output: String?
    let outputCoverage: JSONValue?
    let error: String?
    let imported: Bool?
    let definitionHistory: String?
    let created: Double?
    let started: Double?
    let finished: Double?
    enum CodingKeys: String, CodingKey {
        case id, state, revision, definition, receipt, output, error, imported, created, started, finished
        case outputCoverage = "output_coverage", definitionHistory = "definition_history"
    }
    var isActive: Bool { ["queued", "running", "uncertain"].contains(state) }
}
