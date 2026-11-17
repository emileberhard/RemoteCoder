import Foundation

struct ConversationSettingsSelection: Equatable {
    enum Availability: Equatable {
        case ready
        case loading
        case unavailable(String)
    }

    enum RestoredFrom: String {
        case savedSelection = "saved-selection"
        case thread
    }

    private(set) var model: ModelOption?
    private(set) var reasoning: ReasoningSelection
    private(set) var fastMode: ConversationSpeedState
    private(set) var availability = Availability.ready
    private(set) var revision: UInt64 = 0
    private var reasoningByModelID: [String: ReasoningSelection] = [:]

    init(model: ModelOption?, reasoning: ReasoningSelection, fastMode: ConversationSpeedState) {
        self.model = model
        self.reasoning = reasoning
        self.fastMode = fastMode
    }

    var isReady: Bool { availability == .ready }
    var isLoading: Bool { availability == .loading }
    var fastModeSelection: Bool? { fastMode.selection?.isAccelerated }

    var speedSelection: ConversationSpeed? {
        fastMode.displayedSpeed(for: model)
    }

    var serviceTierOverride: CodexAppServerV2.ServiceTierOverride? {
        fastMode.tierOverride(for: model)
    }

    var unavailableMessage: String? {
        guard case .unavailable(let message) = availability else { return nil }
        return message
    }

    func rememberedReasoning(for model: ModelOption) -> ReasoningSelection? {
        reasoningByModelID[model.id]
    }

    mutating func remember(_ selection: ReasoningSelection, for model: ModelOption) {
        reasoningByModelID[model.id] = selection
    }

    mutating func choose(model: ModelOption?, reasoning: ReasoningSelection, fastMode: ConversationSpeedState) {
        revision &+= 1
        assign(model: model, reasoning: reasoning, fastMode: fastMode)
    }

    mutating func chooseForConversation(model: ModelOption, reasoning: ReasoningSelection,
                                        fastMode: ConversationSpeedState) {
        choose(model: model, reasoning: reasoning, fastMode: fastMode)
        availability = .ready
    }

    mutating func clearModel() {
        revision &+= 1
        model = nil
    }

    mutating func adopt(model: ModelOption, reasoning: ReasoningSelection, fastMode: ConversationSpeedState) {
        assign(model: model, reasoning: reasoning, fastMode: fastMode)
    }

    mutating func adoptModel(_ model: ModelOption) {
        self.model = model
    }

    mutating func restore(model: ModelOption, reasoning: ReasoningSelection, fastMode: ConversationSpeedState) {
        assign(model: model, reasoning: reasoning, fastMode: fastMode)
        availability = .ready
    }

    mutating func observe(model: ModelOption, reasoning: ReasoningSelection, speedState: ConversationSpeedState) {
        if self.model != model || self.reasoning != reasoning || !fastMode.hasSameChoice(as: speedState) {
            revision &+= 1
        }
        assign(model: model, reasoning: reasoning, fastMode: speedState)
        availability = .ready
    }

    mutating func showRecent(model: ModelOption, reasoning: ReasoningSelection, fastMode: ConversationSpeedState) {
        let shown = model.provider == .codex ? ConversationSpeedState.readback(nil, remembered: fastMode.remembered) : fastMode
        restore(model: model, reasoning: reasoning, fastMode: shown)
    }

    mutating func beginLoading() {
        fastMode = .readback(nil, remembered: nil)
        availability = .loading
    }

    mutating func failIfLoading(_ message: String) {
        guard isLoading else { return }
        availability = .unavailable(message)
    }

    mutating func markReady() {
        availability = .ready
    }

    @discardableResult
    mutating func acceptTierReadback(_ extra: CodexAppServerV2.ThreadExtra?, expectedRevision: UInt64) -> Bool {
        guard revision == expectedRevision, let extra, extra.hasServiceTier else { return false }
        fastMode = fastMode.reading(extra)
        return true
    }

    @discardableResult
    mutating func restore(
        from thread: ConversationHeader, saved: ConversationMetadata?,
        resolveOption: (_ modelID: String, _ effort: String?, _ reportedSpeed: ConversationSpeed?) -> ModelOption?
    ) -> RestoredFrom? {
        // An unloaded Claude transcript describes the last run. A newer, explicit
        // settings change may already have selected a different model for its next turn.
        let useSavedSelection = thread.model == nil || (AgentProvider.provider(forThreadID: thread.id) == .claude && thread.status == .notLoaded
            && saved?.source == .selection && (saved?.updatedAt.timeIntervalSince1970 ?? 0) > Double(thread.updatedAt))
        guard let modelID = useSavedSelection ? saved?.modelID : thread.model else { return nil }
        let sameModel = saved.map {
            ClaudeModelCatalog.canonicalModelID($0.modelID) == ClaudeModelCatalog.canonicalModelID(modelID)
        } ?? false
        let savedReasoning = saved.flatMap { ReasoningSelection.fromStorageValue($0.reasoningSelectionID) }
        let reportedEffort = useSavedSelection ? savedReasoning?.effort?.rawValue
            : thread.reasoningEffort?.rawValue ?? (sameModel ? savedReasoning?.effort?.rawValue : nil)
        guard let option = resolveOption(modelID, reportedEffort,
                                        thread.extra?.speedSelection ?? saved?.rememberedSpeed) else { return nil }
        let restoredReasoning: ReasoningSelection
        if !useSavedSelection {
            // Automatic is a user choice; the server reports its resolved level.
            if sameModel, let savedReasoning, savedReasoning == .automatic || thread.reasoningEffort == nil {
                restoredReasoning = savedReasoning
            } else {
                restoredReasoning = thread.reasoningEffort.flatMap { ReasoningEffort(rawValue: $0.rawValue) }
                    .map(ReasoningSelection.effort) ?? .automatic
            }
        } else {
            restoredReasoning = savedReasoning ?? .automatic
        }
        let rememberedSpeed = saved?.rememberedSpeed
        let restoredFastMode = option.provider == .codex
            ? ConversationSpeedState.readback(thread.extra?.speedSelection, remembered: rememberedSpeed)
            : ConversationSpeedState.selection(rememberedSpeed)
        restore(model: option, reasoning: restoredReasoning, fastMode: restoredFastMode)
        return useSavedSelection ? .savedSelection : .thread
    }

    private mutating func assign(model: ModelOption?, reasoning: ReasoningSelection, fastMode: ConversationSpeedState) {
        self.model = model
        self.reasoning = reasoning
        self.fastMode = fastMode
    }
}
