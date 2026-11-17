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
        let choices: [CodexIntentFastMode] = [.off, .on, .ultrafast]
        let available = choices.filter { model.supportsSpeed($0.speed) }
        return available.count > 1 ? [.appDefault] + available : available
    }

    func defaultResult() async -> CodexIntentFastMode? { .appDefault }
}
