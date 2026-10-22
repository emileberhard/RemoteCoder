import Foundation

extension RemoteCoderVoiceConfiguration {
    @MainActor
    func validatedSelection(
        configuredModel: (String) -> NewChatModelLookup,
        defaultModel: () -> NewChatModelLookup,
        preferences: ModelPickerPreferences
    ) throws -> (model: ModelOption, reasoning: ReasoningSelection, fastModeEnabled: Bool) {
        let model: ModelOption
        if let modelID {
            model = try configuredModel(modelID).requireModel(ifNotOffered: .modelNotOffered(modelID))
        } else {
            model = try defaultModel().requireModel(ifNotOffered: .noModelShown)
        }
        let reasoning: ReasoningSelection
        if let reasoningSelectionID {
            guard let selection = ReasoningSelection.fromStorageValue(reasoningSelectionID) else {
                throw VoiceModeConfigurationError.invalidReasoning
            }
            if let effort = selection.effort, !model.reasoningEfforts.contains(effort) {
                throw VoiceModeConfigurationError.unsupportedReasoning(model: model.displayName, reasoning: selection.label)
            }
            reasoning = selection
        } else {
            reasoning = NewChatDefaults.reasoningSelection()
        }
        return (model, preferences.clamped(reasoning, for: model),
                fastModeEnabled && model.supportsFastMode)
    }
}

extension NewChatModelLookup {
    func requireModel(ifNotOffered notOffered: VoiceModeConfigurationError) throws -> ModelOption {
        switch self {
        case .available(let model): return model
        case .hostUnavailable(let provider): throw VoiceModeConfigurationError.hostUnavailable(provider)
        case .listNotLoaded: throw VoiceModeConfigurationError.modelListNotLoaded
        case .notOffered: throw notOffered
        }
    }
}

enum VoiceModeConfigurationError: LocalizedError, CustomLocalizedStringResourceConvertible, Equatable {
    case hostUnavailable(AgentProvider)
    case modelListNotLoaded
    case modelNotOffered(String)
    case noModelShown
    case invalidReasoning
    case unsupportedReasoning(model: String, reasoning: String)
    case groupCall
    case videoCall

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .hostUnavailable(let provider):
            return "A host for \(provider.displayName) is unavailable. Reconnect the host before trying again."
        case .modelListNotLoaded:
            return "RemoteCoder hasn't loaded the Codex model list yet. Try again once it connects to the host."
        case .modelNotOffered(let modelID):
            return "The model \(modelID) is no longer available. Choose another model."
        case .noModelShown:
            return "No models are shown. Choose models in Settings."
        case .invalidReasoning:
            return "Choose a valid reasoning effort for Voice Mode."
        case .unsupportedReasoning(let model, let reasoning):
            return "\(model) doesn't support \(reasoning) reasoning. Choose another effort."
        case .groupCall:
            return "Voice Mode talks to one model at a time. Choose one model."
        case .videoCall:
            return "Voice Mode is audio only."
        }
    }

    var errorDescription: String? { String(localized: localizedStringResource) }
}
