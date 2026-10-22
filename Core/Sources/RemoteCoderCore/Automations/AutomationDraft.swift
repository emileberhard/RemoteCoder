import Foundation

/// An editor changes only the fields it owns. Unknown fields, explicit nulls,
/// checkpoints and unavailable account/model identities survive unrelated edits.
struct AutomationDraft: Equatable, Sendable {
    var definition: AutomationDefinition
    var expectedRevision: Int
    var sourceRevision: Int?

    static func new() -> Self {
        Self(definition: AutomationDefinition(fields: [
            "id": .string(""), "enabled": .bool(false),
            "cwd": .string(""), "timeout": .number(7200),
            "when": .object(["every": .string("1h"), "timezone": .string(TimeZone.current.identifier)]),
            "run": .object(["agent": .object([
                "provider": .string("codex"), "prompt": .string(""),
                "gateway_host": .string("auto"), "session": .string("fresh"),
                "access": .string("full-access"), "if_active": .string("queue")
            ])])
        ]), expectedRevision: 0)
    }

    func value(at path: [String]) -> JSONValue? {
        path.reduce(Optional(JSONValue.object(definition.fields))) { $0?.objectValue?[$1] }
    }
    func text(at path: [String]) -> String { value(at: path)?.stringValue ?? "" }
    mutating func set(_ value: JSONValue?, at path: [String]) {
        definition.fields = Self.setting(value, path: path[...], in: definition.fields)
    }
    private static func setting(_ value: JSONValue?, path: ArraySlice<String>, in fields: [String: JSONValue]) -> [String: JSONValue] {
        guard let key = path.first else { return fields }
        var result = fields
        if path.count == 1 { result[key] = value }
        else { result[key] = .object(setting(value, path: path.dropFirst(), in: fields[key]?.objectValue ?? [:])) }
        return result
    }
    mutating func setTrigger(_ trigger: [String: JSONValue], index: Int) {
        var triggers = definition.triggers
        guard triggers.indices.contains(index) else { return }
        triggers[index] = trigger
        if case .array = definition.fields["when"] { definition.fields["when"] = .array(triggers.map(JSONValue.object)) }
        else { definition.fields["when"] = .object(trigger) }
    }
    mutating func addTrigger() {
        definition.fields["when"] = .array((definition.triggers + [["every": .string("1h"), "timezone": .string(TimeZone.current.identifier)]]).map(JSONValue.object))
    }
    mutating func removeTrigger(at index: Int) {
        var triggers = definition.triggers
        guard triggers.count > 1, triggers.indices.contains(index) else { return }
        triggers.remove(at: index)
        definition.fields["when"] = .array(triggers.map(JSONValue.object))
    }
    mutating func chooseProvider(_ provider: String) {
        set(.string(provider), at: ["run", "agent", "provider"])
        set(nil, at: ["run", "agent", "account"])
    }

    mutating func chooseAction(_ kind: String) {
        var action = definition.fields["run"]?.objectValue ?? [:]
        if kind == "command" {
            action.removeValue(forKey: "agent")
            action["command"] = .array([.string("")])
        } else {
            action.removeValue(forKey: "command")
            action.removeValue(forKey: "finding_exit_codes")
            action["agent"] = Self.new().definition.fields["run"]?.objectValue?["agent"]
        }
        definition.fields["run"] = .object(action)
    }
    private var hostDefaultFields: [String: JSONValue] {
        var draft = self
        draft.set(nil, at: ["run", "agent", "account"])
        return draft.definition.fields
    }

    func saveRequest(requestID: String) -> AutomationRequest {
        AutomationRequest(id: definition.id, data: hostDefaultFields, replaceDefinition: true, requestId: requestID, expectedRevision: expectedRevision)
    }
    func restoreRequest(requestID: String, enabled: Bool) -> AutomationRequest {
        var fields = hostDefaultFields
        fields["enabled"] = .bool(enabled)
        return AutomationRequest(id: definition.id, data: fields, replaceDefinition: true, requestId: requestID,
                                 expectedRevision: expectedRevision, targetRevision: sourceRevision)
    }
}

enum AutomationInventoryFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case active, paused, removed, all
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum AutomationPresentation {
    @concurrent static func prepare(_ items: [AutomationSummary]) async -> [AutomationSummary] {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        return items.map { item in
            var prepared = item
            if let due = item.nextDue {
                let zone = item.nextDueTimezone ?? "UTC"
                if let timezone = TimeZone(identifier: zone) {
                    formatter.timeZone = timezone
                    prepared.nextDueLabel = formatter.string(from: Date(timeIntervalSince1970: due)) + " (" + zone + ")"
                } else { prepared.nextDueLabel = "Schedule timezone unavailable" }
            }
            return prepared
        }
    }

    static func triggerDescription(_ value: JSONValue?) -> String {
        let triggers = value?.arrayValue ?? value.map { [$0] } ?? []
        return triggers.compactMap { trigger -> String? in
            guard let fields = trigger.objectValue else { return nil }
            let timezone = fields["timezone"]?.stringValue ?? "Europe/Stockholm"
            if let every = fields["every"]?.stringValue { return "Every \(every)" }
            if let at = fields["at"]?.stringValue { return "Once: \(at) (\(timezone))" }
            if let cron = fields["cron"]?.stringValue { return "\(cron) (\(timezone))" }
            if let event = fields["event"]?.stringValue { return "Event: \(event)" }
            if let conversation = fields["imessage"] { return "Messages: \(conversation.stringValue ?? "configured conversation")" }
            return "Configured trigger"
        }.joined(separator: " · ")
    }
}

/// Service and gateway rejection are definitive. A dropped response, timeout,
/// malformed acknowledgement or the adapter's uncertainty error keep the exact
/// request so the user can reconcile or retry without a second admission.
enum AutomationMutationFailure {
    static func keepPendingAfterFailure(_ error: any Error, alreadyPending: Bool) -> Bool {
        if error is AutomationServiceError { return false }
        return alreadyPending || acknowledgementUnknown(error)
    }

    static func acknowledgementUnknown(_ error: any Error) -> Bool {
        if error is AutomationServiceError { return false }
        if let failure = error as? GatewayRPCFailure { return failure.kind == .automationAcknowledgementUnknown }
        if let failure = error as? GatewayClient.ClientError {
            switch failure {
            case .serverError, .invalidURL, .notConnected, .retired: return false
            default: return true
            }
        }
        return true
    }
}
