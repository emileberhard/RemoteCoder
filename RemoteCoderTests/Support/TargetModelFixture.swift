import Foundation
import Testing
@testable import RemoteCoder

@MainActor
struct TargetModelFixture {
    let temporaryStorage: TemporaryHostStorage
    let target: ChatTargetModel

    init() {
        let temporary = TemporaryHostStorage()
        temporaryStorage = temporary
        target = ChatTargetModel(chatDefaults: temporary.defaults,
            modelPickerPreferences: ModelPickerPreferences(defaults: temporary.defaults),
            syncedPreferences: SyncedPreferenceStore(defaults: temporary.defaults, keys: []),
            voiceCalls: TestVoiceCalls.center, backgroundExecution: StubBackgroundExecution(), uploadContinuation: ForegroundUploadContinuation(),
            gatewayPolicy: .production, storage: temporary.storage,
            htmlVisuals: HTMLVisualServices(directory: temporary.storage.root.appending(path: "html-visuals")))
    }

    func cleanUp() async {
        target.hostServices.files.beginRetirement()
        let retired = await target.retire()
        await target.hostServices.files.retire()
        guard retired else { Issue.record("Draft retirement failed; fixture storage is retained for recovery"); return }
        temporaryStorage.cleanUp()
    }
}
