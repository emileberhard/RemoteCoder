import Foundation

enum FastModeState: Equatable, Sendable {
    case selection(Bool?)
    case readback(Bool?, remembered: Bool?)

    var selection: Bool? {
        switch self {
        case .selection(let value), .readback(let value, _): value
        }
    }

    var remembered: Bool? {
        switch self {
        case .selection(let value), .readback(_, let value): value
        }
    }

    /// A native readback may change the state's origin without changing the
    /// requested tier or the user's remembered preference.
    func hasSameChoice(as other: Self) -> Bool {
        selection == other.selection && remembered == other.remembered
    }

    func reading(_ extra: CodexAppServerV2.ThreadExtra?) -> Self {
        guard let extra else { return self }
        return observing(extra.fastModeSelection)
    }

    func observing(_ value: Bool?) -> Self {
        .readback(value, remembered: remembered)
    }

    func restoringPreference(_ value: Bool?) -> Self {
        guard remembered == nil, let value else { return self }
        return .readback(selection, remembered: value)
    }

    func choosing(_ value: Bool) -> Self {
        .selection(value)
    }

    func changingModel(from current: ModelOption?, to next: ModelOption) -> Self {
        guard case .readback(let value, let remembered) = self else { return self }
        if current?.supportsFastMode == true, !next.supportsFastMode {
            return .readback(value, remembered: remembered ?? value)
        }
        if current?.supportsFastMode == false, next.supportsFastMode {
            return .readback(remembered ?? value, remembered: remembered)
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
    let fastModeState: FastModeState
    let serviceTier: CodexAppServerV2.ServiceTierOverride?
    let summary = DispatchPolicy.reasoningSummary

    init(threadID: String, model: ModelOption, reasoning: ReasoningSelection,
         fastModeState: FastModeState) {
        threadId = threadID
        self.model = model.id
        effort = reasoning.effort?.rawValue
        self.fastModeState = fastModeState
        serviceTier = fastModeState.selection.map { $0 && model.supportsFastMode ? .set(.fast) : .clear }
    }

    private enum CodingKeys: String, CodingKey {
        case threadId, model, effort, serviceTier, summary
    }

    var reasoningSelection: ReasoningSelection {
        effort.flatMap(ReasoningEffort.init(rawValue:)).map(ReasoningSelection.effort) ?? .automatic
    }

    var fastMode: Bool? { fastModeState.selection }

    func matchesThreadSelection(_ thread: CodexAppServerV2.Thread) -> Bool {
        guard thread.id == threadId, thread.model == model, let effort,
              thread.reasoningEffort?.rawValue == effort else { return false }
        return switch serviceTier {
        case nil: true
        case .clear: thread.extra?.fastModeSelection == false
        case .set(let tier): tier == .fast && thread.extra?.fastModeSelection == true
        }
    }
}
