import AppIntents

struct RemoteCoderCameraCaptureIntent: CameraCaptureIntent {
    static let title: LocalizedStringResource = "RemoteCoder Camera"
    static let description = IntentDescription("Take a photo and attach it to a new RemoteCoder chat.")

    #if REMOTE_CODER_APP
    @Dependency private var workspace: ChatWorkspaceModel
    #endif

    @MainActor
    func perform() async throws -> some IntentResult {
        #if REMOTE_CODER_APP
        workspace.events.receive(.quickAction(RemoteCoderQuickActionRequest(action: .camera)))
        #endif
        return .result()
    }
}
