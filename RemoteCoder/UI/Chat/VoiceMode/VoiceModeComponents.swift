import SwiftUI

struct VoiceCallHeader: View {
    let screen: ChatScreenModel
    let onDismiss: () -> Void
    let onChooseFolder: () -> Void
    let onShowTranscript: () -> Void

    var body: some View {
        ChatHeader(
            screen: screen,
            hostName: screen.target.hostDisplayName,
            favorites: { screen.target.favoriteFolders },
            onChooseFolder: onChooseFolder,
            onSelectFavorite: { screen.selectWorkingDirectory($0.path, ifStillShowing: $1) }
        ) {
            GlassCircleButton(systemImage: "chevron.down", action: onDismiss)
                .accessibilityLabel("Chat")
                .accessibilityHint("The call continues in the background")
                .accessibilityIdentifier("voice-return-to-chat")
        } trailing: {
            GlassCircleButton(systemImage: "text.bubble", action: onShowTranscript)
                .accessibilityLabel("Transcript")
                .accessibilityIdentifier("voice-show-transcript")
        }
    }
}

/// The composer's settings controls bound to the thread the call runs on.
/// Until the call has bound its thread they show the chat's current
/// selection, disabled.
struct VoiceCallSettingsBar: View {
    let screen: ChatScreenModel

    private var bound: ConversationSettingsUpdate? { screen.voiceConversationSettings }

    private var selectedModel: ModelOption? {
        screen.voiceSelectedModel ?? screen.selectedModel
    }

    private var reasoning: ReasoningSelection {
        bound?.reasoningSelection ?? screen.reasoningSelection
    }

    private var fastMode: Bool? {
        if let bound { return bound.fastMode }
        return screen.fastModeSelection
    }

    var body: some View {
        if let selectedModel {
            controls(selectedModel)
        }
    }

    private func controls(_ selectedModel: ModelOption) -> some View {
        ConversationSettingsControls(
            models: screen.target.pickerModelOptions(for: selectedModel),
            model: Binding(get: { selectedModel }, set: { option in
                guard let bound else { return }
                screen.selectModel(option, for: bound.threadId)
            }),
            reasoning: Binding(get: { reasoning }, set: { selection in
                guard let bound else { return }
                screen.selectReasoning(selection, for: bound.threadId)
            }),
            fastMode: Binding(get: { fastMode }, set: { enabled in
                guard let bound else { return }
                if let enabled { screen.selectFastMode(enabled, for: bound.threadId) }
            })
        ) {
            EmptyView()
        }
        .id(bound?.threadId)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .appGlass(.standard, in: .rect(cornerRadius: 28))
        .disabled(bound == nil)
        .accessibilityIdentifier("voice-conversation-settings")
        .task(id: bound?.threadId) { screen.refreshReasoningVisibility() }
    }
}

struct RealtimeVoiceStatus: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appEnergyPolicy) private var energyPolicy
    @Environment(\.visualsVisible) private var visualsVisible

    private var animatesDecorations: Bool {
        energyPolicy.animatesDecorations(sceneActive: scenePhase == .active, visible: visualsVisible, reduceMotion: reduceMotion)
    }

    let state: VoiceCall.State
    let isMuted: Bool

    private var statusSymbol: String {
        if case .failed = state { return "exclamationmark.triangle" }
        return isMuted ? "mic.slash" : "waveform"
    }

    var body: some View {
        VStack(spacing: 24) {
            Group {
                switch state {
                case .ringing, .connecting, .reconnecting, .stopping:
                    ProgressView()
                        .controlSize(.large)
                case .failed, .idle, .listening, .speaking:
                    WorkingSymbol(systemName: statusSymbol, tint: .primary,
                                  isAnimating: animatesDecorations && state == .speaking && !isMuted)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: statusSymbol)
                }
            }
            .scaledFont(.system(size: 48, weight: .regular))
            .frame(height: 64)
            .accessibilityHidden(true)

            Text(state == .listening && isMuted ? "Microphone muted" : state.title)
                .scaledFont(.title2.weight(.semibold))
                .accessibilityIdentifier("voice-call-status")

            if case let .failed(message) = state {
                Text(message)
                    .scaledFont(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct RealtimeVoiceTranscript: View {
    let entries: [RealtimeVoiceTranscriptEntry]
    let liveUserText: String
    let liveAssistantText: String

    var body: some View {
        if entries.isEmpty && liveUserText.isEmpty && liveAssistantText.isEmpty {
            ContentUnavailableView(
                "No transcript yet",
                systemImage: "text.bubble",
                description: Text("Your conversation will appear here as you speak.")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(entries) { entry in
                        VoiceTranscriptRow(role: entry.role, text: entry.text)
                    }

                    if !liveUserText.isEmpty {
                        VoiceTranscriptRow(role: .user, text: liveUserText)
                    }

                    if !liveAssistantText.isEmpty {
                        VoiceTranscriptRow(role: .assistant, text: liveAssistantText)
                    }
                }
                .padding(24)
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.top, for: .alignment)
        }
    }
}

private struct VoiceTranscriptRow: View {
    let role: RealtimeVoiceTranscriptEntry.Role
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(role == .user ? "You" : "Assistant")
                .scaledFont(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(text)
                .scaledFont(.body)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct RealtimeVoiceControls: View {
    let state: VoiceCall.State
    let isActive: Bool
    let isRetrying: Bool
    let isMuted: Bool
    let isUsingSpeaker: Bool
    let audioRouteName: String?
    let onToggleMute: () -> Void
    let onToggleSpeaker: () -> Void
    let onEnd: () -> Void
    let onRetry: () -> Void

    private var audioControlsEnabled: Bool {
        isActive && (state == .listening || state == .speaking)
    }

    var body: some View {
        VStack(spacing: 24) {
            if case .failed = state {
                Button("Try Again", systemImage: "arrow.clockwise", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isRetrying)
            } else {
                HStack(spacing: 16) {
                    Button(action: onToggleMute) {
                        VoiceCallControlLabel(
                            accessibilityLabel: isMuted ? "Unmute" : "Mute",
                            systemImage: isMuted ? "mic.slash.fill" : "mic.fill",
                            appearance: isMuted ? .selected : .normal
                        )
                    }
                    .disabled(!audioControlsEnabled)
                    .accessibilityValue(isMuted ? "Microphone muted" : "Microphone on")
                    .accessibilityIdentifier("voice-toggle-mute")

                    Button(action: onToggleSpeaker) {
                        VoiceCallControlLabel(
                            accessibilityLabel: "Speaker",
                            systemImage: "speaker.wave.2.fill",
                            appearance: isUsingSpeaker ? .selected : .normal
                        )
                    }
                    .disabled(!audioControlsEnabled)
                    .accessibilityValue([isUsingSpeaker ? "On" : "Off", audioRouteName].compactMap { $0 }.joined(separator: ", "))
                    .accessibilityIdentifier("voice-toggle-speaker")

                    Button(role: .destructive, action: onEnd) {
                        VoiceCallControlLabel(
                            accessibilityLabel: "End call",
                            systemImage: "phone.down.fill",
                            appearance: .endCall
                        )
                    }
                    .disabled(!isActive)
                    .accessibilityIdentifier("voice-end-call")
                }
                .buttonStyle(ResponsiveButtonStyle(feedback: nil, pressedScale: 0.94))
            }
        }
    }
}

private struct VoiceCallControlLabel: View {
    enum Appearance {
        case normal
        case selected
        case endCall
    }

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let accessibilityLabel: String
    let systemImage: String
    let appearance: Appearance

    var body: some View {
        Image(systemName: systemImage)
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: systemImage)
            .scaledFont(.system(size: 32, weight: .medium))
            .foregroundStyle(symbolColor)
            .frame(width: 80, height: 80)
            .background(backgroundColor, in: Circle())
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
            .accessibilityLabel(accessibilityLabel)
    }

    private var symbolColor: Color {
        switch appearance {
        case .normal: .primary
        case .selected: Color.appSystemBackground
        case .endCall: .white
        }
    }

    private var backgroundColor: Color {
        switch appearance {
        case .normal: Color.appSecondarySystemBackground
        case .selected: .primary
        case .endCall: .red
        }
    }
}
