import AppIntents
import Foundation

struct VoiceModeReasoningOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<RemoteCoderVoiceChatIntent>(\.$destination)
    private var intent
    @Dependency private var workspace: ChatWorkspaceModel

    func results() async throws -> [CodexIntentReasoning] {
        let entity = try intent?.destination.model
        let workspace = workspace
        let model = try await CodexIntentModelCatalog.resolve(entity, in: workspace)
        let efforts = await MainActor.run {
            workspace.modelPickerPreferences.reasoningEfforts(for: model)
        }
        return [.appDefault, .automatic] + efforts.compactMap {
            CodexIntentReasoning(rawValue: $0.rawValue)
        }
    }

    func defaultResult() async -> CodexIntentReasoning? { .appDefault }
}

struct VoiceModeFastOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<RemoteCoderVoiceChatIntent>(\.$destination)
    private var intent
    @Dependency private var workspace: ChatWorkspaceModel

    func results() async throws -> [CodexIntentFastMode] {
        let entity = try intent?.destination.model
        let workspace = workspace
        let model = try await CodexIntentModelCatalog.resolve(entity, in: workspace)
        return model.supportsFastMode ? [.appDefault, .on, .off] : [.off]
    }

    func defaultResult() async -> CodexIntentFastMode? { .appDefault }
}
