import Foundation

enum ConversationSpeed: String, Codable, CaseIterable, Sendable {
    case standard, fast, ultrafast

    init(accelerated: Bool) {
        self = accelerated ? .fast : .standard
    }

    var isAccelerated: Bool { self != .standard }

    var label: String {
        switch self {
        case .standard: "Standard"
        case .fast: "Fast"
        case .ultrafast: "Ultrafast"
        }
    }

    func tierOverride(for model: ModelOption?) -> CodexAppServerV2.ServiceTierOverride {
        guard model?.supportsSpeed(self) == true else { return .clear }
        return switch self {
        case .standard: .clear
        case .fast: .set(.fast)
        case .ultrafast: .set(.ultrafast)
        }
    }
}

enum ConversationSpeedState: Equatable, Sendable {
    case selection(ConversationSpeed?)
    case readback(ConversationSpeed?, remembered: ConversationSpeed?)

    var selection: ConversationSpeed? {
        switch self {
        case .selection(let value), .readback(let value, _): value
        }
    }

    var remembered: ConversationSpeed? {
        switch self {
        case .selection(let value), .readback(_, let value): value
        }
    }

    func displayedSpeed(for model: ModelOption?) -> ConversationSpeed? {
        if case .readback(.ultrafast, _) = self { return .ultrafast }
        return selection.map { model?.supportsSpeed($0) == false ? .standard : $0 }
    }

    func tierOverride(for model: ModelOption?) -> CodexAppServerV2.ServiceTierOverride? {
        if case .readback(.ultrafast, _) = self, model?.supportsUltrafast != true { return nil }
        return selection?.tierOverride(for: model)
    }

    /// A native readback may change the state's origin without changing the
    /// requested tier or the user's remembered preference.
    func hasSameChoice(as other: Self) -> Bool {
        selection == other.selection && remembered == other.remembered
    }

    func reading(_ extra: CodexAppServerV2.ThreadExtra?) -> Self {
        guard let extra, extra.hasServiceTier else { return self }
        return observing(extra.speedSelection)
    }

    func observing(_ value: ConversationSpeed?) -> Self {
        .readback(value, remembered: remembered)
    }

    func restoringPreference(_ value: ConversationSpeed?) -> Self {
        guard remembered == nil, let value else { return self }
        return .readback(selection, remembered: value)
    }

    func choosing(_ value: ConversationSpeed) -> Self {
        .selection(value)
    }

    func changingModel(from current: ModelOption?, to next: ModelOption) -> Self {
        guard case .readback(let value, let remembered) = self else { return self }
        let preference = remembered ?? value
        if value == .ultrafast, current?.id != next.id, !next.supportsUltrafast {
            return .readback(.standard, remembered: preference)
        }
        if let preference {
            let capability: ConversationSpeed = preference == .standard ? .fast : preference
            if current?.supportsSpeed(capability) == true, !next.supportsSpeed(capability) {
                return .readback(value, remembered: preference)
            }
            if current?.supportsSpeed(capability) == false, next.supportsSpeed(capability) {
                return .readback(preference, remembered: remembered)
            }
        }
        return self
    }
}

struct ConversationSettingsUpdateResponse: Decodable, Sendable {
    enum Status: String, Decodable, Sendable {
        case applied
        case nextTurn
        case targetUnavailable
    }
    let status: Status
    let currentTurnId: String?
    let warning: String?
}

struct ConversationSettingsUpdate: Encodable, Sendable, Equatable {
    let threadId: String
    let model: String
    let effort: String?
    let speedState: ConversationSpeedState
    let serviceTier: CodexAppServerV2.ServiceTierOverride?
    let summary = DispatchPolicy.reasoningSummary

    init(threadID: String, model: ModelOption, reasoning: ReasoningSelection,
         speedState: ConversationSpeedState) {
        threadId = threadID
        self.model = model.id
        effort = reasoning.effort?.rawValue
        self.speedState = speedState
        serviceTier = speedState.tierOverride(for: model)
    }

    private enum CodingKeys: String, CodingKey {
        case threadId, model, effort, serviceTier, summary
    }

    var reasoningSelection: ReasoningSelection {
        effort.flatMap(ReasoningEffort.init(rawValue:)).map(ReasoningSelection.effort) ?? .automatic
    }

    var fastMode: Bool? { speedState.selection?.isAccelerated }

    func matchesThreadSelection(_ thread: CodexAppServerV2.Thread) -> Bool {
        guard thread.id == threadId, thread.model == model, let effort,
              thread.reasoningEffort?.rawValue == effort else { return false }
        return switch serviceTier {
        case nil: true
        case .clear: thread.extra?.speedSelection == .standard
        case .set(let tier): CodexAppServerV2.ServiceTier.speedSelection(for: tier.rawValue).map { $0 == thread.extra?.speedSelection } == true
        }
    }
}
