import Foundation

struct AutomationFieldChange: Identifiable, Equatable, Sendable {
    let path: String
    let before: String
    let after: String
    var id: String { path }
}
struct AutomationComparison: Sendable {
    let fields: [AutomationFieldChange]
    let oldPrompt: String
    let newPrompt: String
    let promptChanges: [AutomationFieldChange]
}

enum AutomationDocuments {
    @concurrent static func pretty(_ value: JSONValue) async throws -> String {
        try prettyValue(value)
    }
    @concurrent static func parseObject(_ text: String) async throws -> [String: JSONValue] {
        guard let fields = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)).objectValue else {
            throw AutomationDocumentError.objectRequired
        }
        return fields
    }
    @concurrent static func compare(_ before: AutomationDefinition, _ after: AutomationDefinition) async throws -> AutomationComparison {
        let oldPrompt = before.agent?["prompt"]?.stringValue ?? ""
        let newPrompt = after.agent?["prompt"]?.stringValue ?? ""
        var old = before.fields
        var new = after.fields
        // Prompt text gets its own bounded line comparison; metadata remains field-based.
        if var run = old["run"]?.objectValue, var agent = run["agent"]?.objectValue {
            agent.removeValue(forKey: "prompt"); run["agent"] = .object(agent); old["run"] = .object(run)
        }
        if var run = new["run"]?.objectValue, var agent = run["agent"]?.objectValue {
            agent.removeValue(forKey: "prompt"); run["agent"] = .object(agent); new["run"] = .object(run)
        }
        var fields: [AutomationFieldChange] = []
        try compareFields(old, new, prefix: "", into: &fields)
        let oldLines = oldPrompt.split(separator: "\n", omittingEmptySubsequences: false)
        let newLines = newPrompt.split(separator: "\n", omittingEmptySubsequences: false)
        var promptChanges: [AutomationFieldChange] = []
        for index in 0..<min(max(oldLines.count, newLines.count), 2000) {
            let left = index < oldLines.count ? String(oldLines[index]) : ""
            let right = index < newLines.count ? String(newLines[index]) : ""
            if left != right { promptChanges.append(AutomationFieldChange(path: "Line \(index + 1)", before: left, after: right)) }
        }
        return AutomationComparison(fields: fields, oldPrompt: oldPrompt, newPrompt: newPrompt, promptChanges: promptChanges)
    }
    private static func compareFields(_ before: [String: JSONValue], _ after: [String: JSONValue], prefix: String,
                                      into changes: inout [AutomationFieldChange]) throws {
        for key in Set(before.keys).union(after.keys).sorted() {
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let left = before[key]?.objectValue, let right = after[key]?.objectValue {
                try compareFields(left, right, prefix: path, into: &changes)
            } else if before[key] != after[key] {
                changes.append(AutomationFieldChange(path: path, before: try before[key].map(prettyValue) ?? "Absent",
                                                     after: try after[key].map(prettyValue) ?? "Absent"))
            }
        }
    }
    private static func prettyValue(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

enum AutomationDocumentError: LocalizedError {
    case objectRequired
    var errorDescription: String? { "Enter a JSON object." }
}
