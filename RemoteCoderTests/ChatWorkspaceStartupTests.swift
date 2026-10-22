import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import RemoteCoder

@Suite(.serialized)
@MainActor
struct ChatWorkspaceStartupTests {
    @Test func keepingTheAppOpenRestartsItsCancelledAccountImport() async throws {
        let fixture = await WorkspaceFixture(notificationsEnabled: false)
        defer { await fixture.cleanUp() }
        await fixture.workspace.retireEverything()
        let host = fixture.mini.id, account = UUID()
        let folder = fixture.temporaryStorage.storage.directory(for: .account(host: host, account: account))
        let context = try ComposerDraftStore.makeContext(directory: folder.appending(path: "drafts"))
        let draft = ComposerDraft(destination: ComposerDraftStore.Destination.thread("retained").key)
        draft.text = "Keep this draft"
        context.insert(draft)
        try context.save()
        let workspace = ChatWorkspaceModel(settings: fixture.workspace.settings, defaults: fixture.defaults,
            voiceCalls: TestVoiceCalls.center, makeBackgroundExecution: { StubBackgroundExecution() }, uploadContinuation: ForegroundUploadContinuation(),
            gatewayPolicy: .production, storage: fixture.temporaryStorage.storage)
        defer { await workspace.retireEverything() }
        workspace.beginTermination()
        #expect(await workspace.flushForTermination().isEmpty)
        #expect(workspace.models.isEmpty)
        workspace.resumeAfterTermination()
        await workspace.finishHostChanges()
        let target = try #require(workspace.selectedScreen).target
        #expect(await target.drafts.draft(for: .thread("retained"))?.text == "Keep this draft")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(workspace.accountMigrationIssue == nil)
    }

    @Test(.timeLimit(.minutes(1))) func keepingTheAppOpenDoesNotRetryAnAlreadyAdmittedHost() async throws {
        let fixture = await WorkspaceFixture(notificationsEnabled: false)
        defer { await fixture.cleanUp() }
        await fixture.workspace.retireEverything()
        let hosts = [fixture.mini, fixture.book].sorted { $0.id.uuidString < $1.id.uuidString }
        let failed = hosts[0], pending = hosts[1], failedAccount = UUID(), pendingAccount = UUID()
        let storage = fixture.temporaryStorage.storage
        let failedFolder = storage.directory(for: .account(host: failed.id, account: failedAccount))
        try FileManager.default.createDirectory(at: failedFolder, withIntermediateDirectories: true)
        try Data("invalid metadata".utf8).write(to: failedFolder.appending(path: "codex-session-metadata.json"))
        let pendingFolder = storage.directory(for: .account(host: pending.id, account: pendingAccount))
        let context = try ComposerDraftStore.makeContext(directory: pendingFolder.appending(path: "drafts"))
        let draft = ComposerDraft(destination: ComposerDraftStore.Destination.thread("retained").key)
        draft.text = "Pending host draft"
        context.insert(draft)
        try context.save()
        let conversation = UUID()
        let checkpoint = ConversationState(conversationID: conversation, threadID: "retained").checkpoint
        let source = ConversationCheckpointStore(hostID: pending.id,
            directory: storage.root.appending(path: "conversations-v1/\(pending.id)/accounts/\(pendingAccount)"),
            storage: storage, primaryBudgetBytes: 512 * 1_024 * 1_024)
        try await source.save(checkpoint, conversationID: conversation)
        weak var workspace: ChatWorkspaceModel?
        let defaults = fixture.defaults
        let created = ChatWorkspaceModel(settings: fixture.workspace.settings, defaults: defaults,
            makeModel: { host, preferences, synced in
                if host.id == failed.id {
                    Task { workspace?.beginTermination() }
                }
                return ChatTargetModel(host: host, chatDefaults: defaults, modelPickerPreferences: preferences,
                    syncedPreferences: synced, voiceCalls: TestVoiceCalls.center, backgroundExecution: StubBackgroundExecution(), uploadContinuation: ForegroundUploadContinuation(),
                    gatewayPolicy: .production, storage: storage,
                    htmlVisuals: HTMLVisualServices(directory: storage.root.appending(path: "html-visuals")))
            }, voiceCalls: TestVoiceCalls.center, makeBackgroundExecution: { StubBackgroundExecution() }, uploadContinuation: ForegroundUploadContinuation(),
            gatewayPolicy: .production, storage: storage)
        workspace = created
        defer { await created.retireEverything() }
        while !created.isQuiescing { await Task.yield() }
        #expect(await created.flushForTermination().isEmpty)
        #expect(created.models.map(\.hostID) == [failed.id])
        #expect(FileManager.default.fileExists(atPath: pendingFolder.path))
        let journal = storage.directory(for: .host(failed.id)).appending(path: "retired-accounts/\(failedAccount).json")
        let before = try Data(contentsOf: journal)
        let admitted = try #require(created.model(for: failed.id))
        created.resumeAfterTermination()
        await created.finishHostChanges()
        #expect(created.model(for: failed.id) === admitted)
        #expect(created.model(for: pending.id) != nil)
        #expect(try Data(contentsOf: journal) == before)
        #expect(created.accountMigrationIssue != nil)
        #expect(!FileManager.default.fileExists(atPath: pendingFolder.path))
    }

    @Test func anEnrollmentWindowRestoresItsIndependentNewChatSetup() async throws {
        let fixture = await WorkspaceFixture(notificationsEnabled: false)
        defer { await fixture.cleanUp() }
        await fixture.workspace.retireEverything()
        let host = fixture.mini.id, account = UUID(), slot = UUID()
        for (scope, path, text) in [(StorageScope.host(host), "/repo/A", "Draft A"),
                                   (.account(host: host, account: account), "/repo/B", "Draft B")] {
            let context = try ComposerDraftStore.makeContext(directory: fixture.temporaryStorage.storage.directory(for: scope).appending(path: "drafts"))
            let draft = ComposerDraft(destination: ComposerDraftStore.Destination.newChat(slot).key)
            draft.text = text
            draft.newChat = .init(workingDirectory: path, modelID: CodexModelFixtures.solID, reasoning: .effort(.high), fastMode: true)
            context.insert(draft)
            try context.save()
        }
        fixture.defaults.set(["host": host.uuidString, "account": account.uuidString, "draft": slot.uuidString], forKey: "workspace.open-conversation.v1")
        let workspace = try await fixture.relaunch()
        let screen = try #require(workspace.selectedScreen)
        await screen.target.restoreCachedCodexModels()
        #expect(await screen.prepareDraft())
        #expect(screen.input == "Draft B")
        #expect(screen.workingDirectory == "/repo/B")
        #expect(screen.newChatDraftID != slot)
        let original = try #require(await screen.target.drafts.draft(for: .newChat(slot)))
        #expect(original.text == "Draft A")
        #expect(original.newChat?.workingDirectory == "/repo/A")
    }

    @Test func mountingTheRootReplacesRetiredAccountSelectionWithItsHost() async throws {
        let fixture = await WorkspaceFixture(notificationsEnabled: false)
        defer { await fixture.cleanUp() }
        await fixture.workspace.retireEverything()
        let accountID = UUID()
        let account = ProviderAccountSnapshot(
            id: accountID.uuidString, provider: .codex, label: "Saved account",
            enabled: true, generation: 1, isDefault: false,
            identity: .init(key: "saved-account", email: nil, workspace: nil),
            plan: "pro", state: .ready, windows: [], observedAt: 100,
            stale: false, error: nil, activeTurns: 0,
            incomingCallRoutingId: nil
        )
        try await AccountDirectoryStore(storage: fixture.temporaryStorage.storage).save(
            .init(schemaVersion: 2, accounts: [account], refreshing: false),
            hostID: fixture.mini.id
        )
        fixture.defaults.set(
            [fixture.mini.id.uuidString: accountID.uuidString],
            forKey: "accounts.selected-by-host.v1"
        )
        let workspace = try await fixture.relaunch()
        defer { await workspace.retireEverything() }
        #expect(workspace.selectedHost != nil)
        #expect(workspace.keyWindow.selectedTarget == ExecutionTarget(hostID: fixture.mini.id))

        let app = RemoteCoderAppModel(workspace: workspace, voiceCalls: TestVoiceCalls.center, scenes: ScenePhaseAggregate())
        app.start()
        defer { app.terminate() }

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: ChatRootView(workspace: workspace, sceneValue: .constant(nil))
            .environment(workspace.settings)
            .environment(workspace.modelPickerPreferences)
            .environment(AppThemeStore())
            .environment(\.scenePhase, .active))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKey() }

        #expect(await waitUntil { workspace.selectedScreen?.hostID == fixture.mini.id })
        let restored = try #require(workspace.selectedModel)
        #expect(restored.hostID == fixture.mini.id)
        #expect(restored.isVisible)
        #expect(!restored.isRetired)
        #expect(workspace.keyWindow.selectedTarget == ExecutionTarget(hostID: fixture.mini.id))
    }
}
