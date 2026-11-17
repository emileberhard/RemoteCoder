import Foundation

enum NewChatDefaults {
    static let modelDefaultKey = "codex.newChatModel"
    static let reasoningDefaultKey = "codex.newChatReasoning"
    static let lastSelectedValue = "last-selected"
    static let initialCodexModelID = "gpt-6.1-sol"

    // Existing values seed the last selection when upgrading.
    private static let modelIDKey = "codex.defaultModelID"
    private static let reasoningSelectionKey = "codex.defaultReasoningSelection"
    private static let fastModeKey = "codex.fastModeEnabled"

    private static let speedKey = "codex.speed"

    static let syncedKeys: Set<String> = [modelDefaultKey, reasoningDefaultKey, modelIDKey, reasoningSelectionKey, fastModeKey, speedKey]

    static func preferredModelID(defaults: UserDefaults = AppStorageScope.current.defaults) -> String? {
        if let fixed = defaults.string(forKey: modelDefaultKey), fixed != lastSelectedValue {
            return fixed
        }
        return defaults.string(forKey: modelIDKey)
    }

    static func recordModelSelection(_ modelID: String, defaults: UserDefaults = AppStorageScope.current.defaults) {
        defaults.set(modelID, forKey: modelIDKey)
    }

    static func reasoningSelection(defaults: UserDefaults = AppStorageScope.current.defaults) -> ReasoningSelection {
        if let fixed = defaults.string(forKey: reasoningDefaultKey), fixed != lastSelectedValue,
           let selection = ReasoningSelection.fromStorageValue(fixed) {
            return selection
        }
        guard let stored = defaults.string(forKey: reasoningSelectionKey) else {
            return .effort(.high)
        }
        return ReasoningSelection.fromStorageValue(stored) ?? .effort(.high)
    }

    static func recordReasoningSelection(
        _ selection: ReasoningSelection,
        defaults: UserDefaults = AppStorageScope.current.defaults
    ) {
        defaults.set(selection.id, forKey: reasoningSelectionKey)
    }

    static func fastModeEnabled(defaults: UserDefaults = AppStorageScope.current.defaults) -> Bool {
        speed(defaults: defaults).isAccelerated
    }

    static func speed(defaults: UserDefaults = AppStorageScope.current.defaults) -> ConversationSpeed {
        let stored = defaults.string(forKey: speedKey).flatMap(ConversationSpeed.init(rawValue:))
        guard defaults.object(forKey: fastModeKey) != nil else { return stored ?? .standard }
        let accelerated = defaults.bool(forKey: fastModeKey)
        guard let stored, stored.isAccelerated == accelerated else { return ConversationSpeed(accelerated: accelerated) }
        return stored
    }

    static func recordSpeed(_ speed: ConversationSpeed, defaults: UserDefaults = AppStorageScope.current.defaults) {
        defaults.set(speed.rawValue, forKey: speedKey)
        defaults.set(speed.isAccelerated, forKey: fastModeKey)
    }

    static func setFastModeEnabled(_ enabled: Bool, defaults: UserDefaults = AppStorageScope.current.defaults) {
        recordSpeed(ConversationSpeed(accelerated: enabled), defaults: defaults)
    }
}
