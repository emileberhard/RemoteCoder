import SwiftUI

struct RealtimeVoiceSettingsSection: View {
    let workspace: ChatWorkspaceModel

    var body: some View {
        let voice = workspace.voiceCalls.call

        Section {
            Picker("Voice", selection: Binding(get: { voice.effectiveVoice }, set: { voice.selectedVoice = $0 })
                .nativeSelectionFeedback()) {
                ForEach(voice.voices, id: \.self) { option in
                    Text(option.capitalized).tag(Optional(option))
                }
            }
            .disabled(voice.voices.isEmpty || voice.isActive)

            if let error = voice.voiceCatalogError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .scaledFont(.subheadline)
                    .foregroundStyle(.red)
            } else if voice.voices.isEmpty {
                ProgressView("Loading voices…")
            }
        } header: {
            Text("Voice Mode")
        } footer: {
            if voice.isActive {
                Text("End the call to change voices.")
            }
        }
        .task {
            guard let host = workspace.selectedModel else { return }
            await voice.refreshVoiceCatalog(using: host)
        }
    }
}
