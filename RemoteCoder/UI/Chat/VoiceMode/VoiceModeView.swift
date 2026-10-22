import SwiftUI

enum VoiceModeEntry: Hashable, Identifiable {
    case startCall
    case presentCall(UUID)

    var id: Self { self }
}

struct VoiceModeView: View {
    @State private var hasStarted = false
    @State private var isRetrying = false
    @State private var showsTranscript = false
    @State private var showsDirectoryPicker = false
    @State private var audioRouteError: String?

    let screen: ChatScreenModel
    let entry: VoiceModeEntry
    @Binding var isPresented: Bool

    private var voice: VoiceCall { screen.target.realtimeVoice }

    var body: some View {
        ZStack {
            ThemedAppBackground()

            ScrollView {
                RealtimeVoiceStatus(state: voice.state, isMuted: voice.isMuted)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            }
            .defaultScrollAnchor(.center, for: .alignment)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VoiceCallHeader(
                screen: screen,
                onDismiss: dismiss,
                onChooseFolder: { showsDirectoryPicker = true },
                onShowTranscript: { showsTranscript = true }
            )
            .frame(maxWidth: 600)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    VoiceCallSettingsBar(screen: screen)
                    ConversationSettingsStatus(screen: screen, threadID: voice.conversationContext?.threadID)
                }

                RealtimeVoiceControls(
                    state: voice.state,
                    isActive: voice.isActive,
                    isRetrying: isRetrying,
                    isMuted: voice.isMuted,
                    isUsingSpeaker: voice.audioRoute.isUsingSpeaker,
                    audioRouteName: voice.audioRoute.outputName,
                    onToggleMute: toggleMute,
                    onToggleSpeaker: toggleSpeaker,
                    onEnd: endCall,
                    onRetry: retry
                )
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
        }
        .reasoningPickerOverlay()
        .directoryQuickSwitchOverlay(isEnabled: !showsDirectoryPicker && !showsTranscript)
        .sheet(isPresented: $showsDirectoryPicker) {
            DirectoryPickerView(
                directories: screen.target.directories,
                favorites: screen.target.favoriteFolders,
                currentWorkingDirectory: screen.workingDirectory,
                prefetchedRootChildren: screen.target.directories.homeChildren?.childItems ?? [],
                folderListID: ObjectIdentifier(screen),
                hostSwitcher: { EmptyView() },
                onSelectFavorite: { screen.selectWorkingDirectory($0.path) },
                onRemoveFavorite: { screen.target.directories.removeFavorite($0.path) }
            ) { selectedPath in
                screen.selectWorkingDirectory(selectedPath)
            }
        }
        .sheet(isPresented: $showsTranscript) {
            NavigationStack {
                RealtimeVoiceTranscript(
                    entries: voice.transcript,
                    liveUserText: voice.liveUserText,
                    liveAssistantText: voice.liveAssistantText
                )
                .navigationTitle("Transcript")
                .inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(role: .close) { showsTranscript = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .alert("Couldn't change speaker", isPresented: Binding(
            get: { audioRouteError != nil },
            set: { if !$0 { audioRouteError = nil } }
        )) {
            Button("OK", role: .cancel) { audioRouteError = nil }
        } message: {
            Text(audioRouteError ?? "")
        }
        .onAppear {
            VoiceModeDiagnostics.log("voice cover appeared")
        }
        .onChange(of: voice.state) { oldState, newState in
            guard hasStarted, !isRetrying, newState == .idle, oldState == .stopping else { return }
            VoiceModeDiagnostics.log("voice cover dismissed on terminal idle")
            isPresented = false
        }
        .task {
            guard !hasStarted else { return }
            hasStarted = true
            VoiceModeDiagnostics.log("voice cover task started")
            switch entry {
            case .startCall:
                await voice.start(using: screen.target)
            case .presentCall(let callID):
                guard voice.liveCallID != callID else { return }
                VoiceModeDiagnostics.log("voice cover closed for ended call=\(callID)")
                isPresented = false
            }
        }
    }

    private func dismiss() {
        isPresented = false
    }

    private func toggleMute() {
        Task { await voice.toggleMute() }
    }

    private func toggleSpeaker() {
        do {
            try voice.audioRoute.toggleSpeaker()
        } catch {
            audioRouteError = error.localizedDescription
            VoiceModeDiagnostics.log(
                "voice route change failed error=\(error.localizedDescription)"
            )
        }
    }

    private func endCall() {
        Task {
            await voice.stop()
            isPresented = false
        }
    }

    private func retry() {
        guard !isRetrying else { return }
        HapticService.shared.play(.buttonPress)
        isRetrying = true
        Task {
            await voice.retry()
            isRetrying = false
        }
    }
}
