import AppIntents
import Foundation
import UIKit

struct RemoteCoderNewChatIntent: AppIntent {
    static let title: LocalizedStringResource = "New Chat"
    static let description = IntentDescription(
        "Start a new RemoteCoder conversation in your home directory with the keyboard open."
    )
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]

    static var parameterSummary: some ParameterSummary {
        Summary("Start a new chat in RemoteCoder")
    }

    @Dependency private var workspace: ChatWorkspaceModel

    @MainActor
    func perform() async throws -> some IntentResult {
        workspace.events.receive(.quickAction(RemoteCoderQuickActionRequest(action: .newChat)))
        return .result()
    }
}

@AppIntent(schema: .phone.startCall)
struct RemoteCoderVoiceChatIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Voice Mode"
    static let description = IntentDescription(
        "Start a new voice conversation in your home directory with your choice of model, reasoning effort, and Fast Mode. App Default uses your new-chat settings."
    )
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]

    @Parameter(title: "Model")
    var destination: VoiceCallDestination

    @Parameter(title: "Mode", default: .audio)
    var audioVisualMode: VoiceCallMode

    @Parameter(title: "Reasoning Effort", default: .appDefault, optionsProvider: VoiceModeReasoningOptionsProvider())
    var reasoning: CodexIntentReasoning?

    @Parameter(title: "Fast Mode", default: .appDefault, optionsProvider: VoiceModeFastOptionsProvider())
    var fastMode: CodexIntentFastMode?

    @Dependency private var workspace: ChatWorkspaceModel

    static var parameterSummary: some ParameterSummary {
        Summary("Start Voice Mode with \(\.$destination)") {
            \.$reasoning
            \.$fastMode
        }
    }

    var voiceConfiguration: RemoteCoderVoiceConfiguration {
        get throws {
            guard audioVisualMode == .audio else { throw VoiceModeConfigurationError.videoCall }
            let model = try destination.model
            return RemoteCoderVoiceConfiguration(
                modelID: model.id == CodexModelEntity.appDefaultID ? nil : model.id,
                reasoningSelectionID: reasoning?.selectionID,
                fastModeEnabled: (fastMode ?? .appDefault).isEnabled
            )
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let context = systemContext
        let unlocked = UIApplication.shared.isProtectedDataAvailable
        VoiceModeDiagnostics.log(
            "voice intent perform started unlocked=\(unlocked) canForeground=\(context.currentMode.canContinueInForeground) voiceOnly=\(context.isVoiceOnly)"
        )
        let callID = try await workspace.startFreshVoiceCall(configuration: try voiceConfiguration)
        if unlocked, let callID {
            workspace.events.receive(.presentVoiceCall(callID))
            if context.currentMode.canContinueInForeground {
                do {
                    try await continueInForeground(alwaysConfirm: false)
                } catch {
                    VoiceModeDiagnostics.log("voice intent stayed in background error=\(error.localizedDescription)")
                }
            }
        }
        VoiceModeDiagnostics.log("voice intent perform completed")
        return .result()
    }
}
