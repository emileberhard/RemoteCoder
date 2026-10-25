import Foundation

enum ReasoningEffort: String, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra

    var id: String { rawValue }

    var label: String {
        switch self {
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        case .xhigh:
            return "X-High"
        case .max:
            return "Max"
        case .ultra:
            return "Ultra"
        }
    }
}

enum ReasoningSelection: Hashable, Identifiable, Sendable {
    case automatic
    case effort(ReasoningEffort)

    var id: String {
        switch self {
        case .automatic:
            return "automatic"
        case .effort(let effort):
            return "effort-\(effort.rawValue)"
        }
    }

    var label: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .effort(let effort):
            return effort.label
        }
    }

    static func choices(among efforts: [ReasoningEffort]) -> [ReasoningSelection] {
        [.automatic] + efforts.map(ReasoningSelection.effort)
    }

    var effort: ReasoningEffort? {
        switch self {
        case .automatic:
            return nil
        case .effort(let effort):
            return effort
        }
    }

    static func fromStorageValue(_ raw: String?) -> ReasoningSelection? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        if trimmed == "automatic" { return .automatic }
        if trimmed.hasPrefix("effort-") {
            let suffix = String(trimmed.dropFirst("effort-".count))
            if let effort = ReasoningEffort(rawValue: suffix) {
                return .effort(effort)
            }
        }
        if let effort = ReasoningEffort(rawValue: trimmed) {
            return .effort(effort)
        }
        return nil
    }
}

enum ModelSelectionError: LocalizedError {
    case noModelToSend
    case noModelForVoice

    var errorDescription: String? {
        switch self {
        case .noModelToSend:
            return "Choose a model before sending."
        case .noModelForVoice:
            return "Choose a model before starting Voice Mode."
        }
    }
}

struct ModelOption: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let reasoningEfforts: [ReasoningEffort]
    let supportsFastMode: Bool
    let supportsDaybreakBlue: Bool
    let acceptsImages: Bool
    let provider: AgentProvider
    let modelProvider: CodexAppServerV2.ModelProvider?
    let isListed: Bool

    var pickerTitle: String {
        modelProvider.map { "\(displayName) · \($0.name)" } ?? displayName
    }

    var automaticCyberAccessProgram: CodexAppServerV2.CyberAccessProgram? {
        supportsDaybreakBlue ? .daybreakBlue : nil
    }

    static func unlisted(id: String, modelProvider: CodexAppServerV2.ModelProvider?, reportedEffort: ReasoningEffort?,
                         reportedFastMode: Bool) -> ModelOption {
        ModelOption(
            id: id,
            displayName: modelProvider == nil ? id : readableName(of: id),
            reasoningEfforts: reportedEffort.map { [$0] } ?? [],
            supportsFastMode: reportedFastMode,
            supportsDaybreakBlue: false,
            acceptsImages: true,
            provider: .codex,
            modelProvider: modelProvider,
            isListed: false
        )
    }

    private static func readableName(of id: String) -> String {
        let name = id.split(separator: "/").last.map(String.init) ?? id
        return name.split { $0 == "-" || $0 == "_" }.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

extension AgentProvider {
    static func provider(forModelID id: String) -> AgentProvider {
        ClaudeModelCatalog.model(for: id) == nil ? .codex : .claude
    }
}

enum ClaudeModelCatalog {
    static let fableModelID = "fable"
    static let opusModelID = "opus"
    static let sonnetModelID = "sonnet"
    static let haikuModelID = "haiku"
    // Every Claude row takes the same reasoning profile: `claude --effort`
    // accepts low through max for all four models. Claude Code runs Fast
    // mode only on Opus.
    static let defaultModel = model(id: fableModelID, displayName: "Claude Fable", supportsFastMode: false)
    static let models: [ModelOption] = [
        defaultModel,
        model(id: opusModelID, displayName: "Claude Opus", supportsFastMode: true),
        model(id: sonnetModelID, displayName: "Claude Sonnet", supportsFastMode: false),
        model(id: haikuModelID, displayName: "Claude Haiku", supportsFastMode: false)
    ]

    static func model(for id: String) -> ModelOption? {
        models.first(where: { $0.id == canonicalModelID(id) })
    }

    // Saved defaults and session metadata from the numbered picker follow the
    // same family now. Remove these mappings once those persisted IDs retire.
    static func canonicalModelID(_ id: String) -> String {
        switch id {
        case let value where value.hasPrefix("claude-fable-"): fableModelID
        case let value where value.hasPrefix("claude-opus-"): opusModelID
        case let value where value.hasPrefix("claude-sonnet-"): sonnetModelID
        case let value where value.hasPrefix("claude-haiku-"): haikuModelID
        default: id
        }
    }

    private static func model(id: String, displayName: String, supportsFastMode: Bool) -> ModelOption {
        ModelOption(
            id: id,
            displayName: displayName,
            reasoningEfforts: [.low, .medium, .high, .xhigh, .max],
            supportsFastMode: supportsFastMode,
            supportsDaybreakBlue: false,
            acceptsImages: true,
            provider: .claude,
            modelProvider: nil,
            isListed: true
        )
    }
}
