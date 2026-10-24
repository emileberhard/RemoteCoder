import Foundation
import Synchronization
import Testing
@testable import RemoteCoder
import SpeechKit

/// Two configured hosts with real chat models, pointed at a refused local port.
///
/// The models are real on purpose: what these tests assert is lifecycle and
/// ownership, and a stub would prove nothing about the object the app runs.
/// `127.0.0.1` ports 1 and 2 refuse immediately, so every gateway call fails fast instead of
/// waiting out a DNS lookup while the two endpoints remain distinct.
@MainActor
final class WorkspaceFixture {
    private enum RelaunchFailure: Error { case draftRetirement }
    private let suiteName: String
    let mini: GatewayHostConfiguration
    let book: GatewayHostConfiguration
    let defaults: UserDefaults
    let temporaryStorage: TemporaryHostStorage
    let workspace: ChatWorkspaceModel
    private var relaunchedWorkspaces: [ChatWorkspaceModel] = []

    init(
        notificationsEnabled: Bool = true,
        loadConversationHeader: @escaping @MainActor (ChatTargetModel, String) async throws -> ConversationHeader = {
            try await $0.conversationHeader(threadID: $1)
        },
        notificationApplicationIsActive: @escaping @MainActor () -> Bool = { true },
        miniGatewayPort: Int? = nil,
        bookGatewayPort: Int? = nil,
        temporaryStorage: TemporaryHostStorage = TemporaryHostStorage()
    ) async {
        self.temporaryStorage = temporaryStorage
        suiteName = "RemoteCoderTests.\(UUID().uuidString)"
        guard let isolatedDefaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create isolated test defaults")
        }
        defaults = isolatedDefaults
        mini = miniGatewayPort.map {
            GatewayHostConfiguration(id: UUID(), name: "Mac Mini", hostname: "127.0.0.1", port: $0,
                                     authToken: "mini-token", transport: .trustedNetwork)
        } ?? GatewayHostConfiguration(
            id: UUID(), name: "Mac Mini", hostname: "127.0.0.1", port: 1, authToken: "mini-token"
        )
        book = bookGatewayPort.map {
            GatewayHostConfiguration(id: UUID(), name: "MacBook", hostname: "127.0.0.1", port: $0,
                                     authToken: "book-token", transport: .trustedNetwork)
        } ?? GatewayHostConfiguration(
            id: UUID(), name: "MacBook", hostname: "127.0.0.1", port: 2, authToken: "book-token"
        )
        defaults.set(notificationsEnabled, forKey: TaskCompletionNotificationConstants.completionNotificationsEnabledDefaultsKey)
        let chatDefaults = defaults
        let storage = temporaryStorage.storage
        for host in [mini, book] {
            do {
                try CodexModelFixtures.seed(hostID: host.id, storage: storage)
                try Self.seedSynchronizedMarks(hostID: host.id, storage: storage)
            }
            catch { Issue.record("Could not seed \(host.name): \(error)") }
        }
        workspace = ChatWorkspaceModel(
            settings: HostStore(hosts: [mini, book], activeHostID: mini.id, defaults: defaults, credentials: MemoryGatewayCredentials()),
            defaults: defaults,
            makeModel: { ChatTargetModel(host: $0, chatDefaults: chatDefaults, modelPickerPreferences: $1, syncedPreferences: $2, voiceCalls: TestVoiceCalls.center, backgroundExecution: StubBackgroundExecution(), uploadContinuation: ForegroundUploadContinuation(), gatewayPolicy: .production, storage: storage, htmlVisuals: HTMLVisualServices(directory: storage.root.appending(path: "html-visuals"))) },
            loadConversationHeader: loadConversationHeader,
            notificationApplicationIsActive: notificationApplicationIsActive,
            voiceCalls: TestVoiceCalls.center, makeBackgroundExecution: { StubBackgroundExecution() }, uploadContinuation: ForegroundUploadContinuation(), gatewayPolicy: .production,
            storage: storage
        )
        await workspace.finishHostChanges()
    }

    func cleanUp() async {
        guard await retireWorkspaces() else { Issue.record("Draft retirement failed; fixture storage is retained for recovery"); return }
        relaunchedWorkspaces.removeAll()
        temporaryStorage.cleanUp()
        defaults.removePersistentDomain(forName: suiteName)
    }

    @discardableResult
    func selectColdHost(lastKnownHomePath: String? = nil) throws -> ChatTargetModel {
        let host = GatewayHostConfiguration(id: UUID(), name: "Cold host", hostname: "127.0.0.1", port: 3, authToken: "fixture-token")
        try CodexModelFixtures.seed(hostID: host.id, storage: temporaryStorage.storage)
        if let lastKnownHomePath { HostPreferences.setRemoteHomePath(lastKnownHomePath, hostID: host.id, defaults: defaults) }
        workspace.settings.upsert(host)
        workspace.reconcileHosts()
        workspace.select(hostID: host.id)
        return try #require(workspace.selectedScreen).target
    }

    func restoreCachedModels() async {
        for model in workspace.models { await model.restoreCachedCodexModels() }
    }

    func relaunch() async throws -> ChatWorkspaceModel {
        guard await retireWorkspaces() else { throw RelaunchFailure.draftRetirement }
        let defaults = self.defaults
        let storage = temporaryStorage.storage
        let restored = ChatWorkspaceModel(settings: workspace.settings, defaults: defaults,
            makeModel: { ChatTargetModel(host: $0, chatDefaults: defaults, modelPickerPreferences: $1, syncedPreferences: $2, voiceCalls: TestVoiceCalls.center, backgroundExecution: StubBackgroundExecution(), uploadContinuation: ForegroundUploadContinuation(), gatewayPolicy: .production, storage: storage, htmlVisuals: HTMLVisualServices(directory: storage.root.appending(path: "html-visuals"))) },
            voiceCalls: TestVoiceCalls.center, makeBackgroundExecution: { StubBackgroundExecution() }, uploadContinuation: ForegroundUploadContinuation(), gatewayPolicy: .production, storage: storage)
        await restored.finishHostChanges()
        relaunchedWorkspaces.append(restored)
        return restored
    }

    private func retireWorkspaces() async -> Bool {
        var retired = await workspace.retireEverything()
        for workspace in relaunchedWorkspaces {
            if await !workspace.retireEverything() { retired = false }
        }
        return retired
    }

    private static func seedSynchronizedMarks(hostID: UUID, storage: HostStorage) throws {
        let directory = storage.directory(for: .target(hostID: hostID))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = ConversationMarks(
            schemaVersion: 1, revision: 0, readBaseline: Int64(Date.now.timeIntervalSince1970), threads: [:], supportsRetiredScopeRead: true)
        var synchronized = ConversationMarksReplica(acknowledged: snapshot)
        synchronized.retireDefaultScope()
        synchronized.replaceAcknowledged(snapshot)
        try JSONEncoder().encode(synchronized).write(to: directory.appending(path: ConversationMarksStore.fileName))
    }

    func thread(_ id: String, updatedAt: Int64, path: String? = nil) throws -> ConversationHeader {
        var fields: [String: Any] = [:]
        if let path { fields["path"] = path }
        return try ThreadFixture.basic(id, updatedAt: updatedAt, fields: fields)
    }
}

extension ChatWorkspaceModel {
    @discardableResult
    func retireEverything() async -> Bool {
        var retired = true
        teardown()
        for model in models {
            model.hostServices.files.beginRetirement()
            model.beginRetirement()
        }
        for model in models {
            await model.hostServices.files.retire()
            if await !model.retire() { retired = false }
        }
        if await !finishHostChanges() { retired = false }
        return retired
    }
}

/// Holds no background time and reports only the calls a target made.
@MainActor
final class StubBackgroundExecution: BackgroundExecution {
    private(set) var holds: [String] = []
    private(set) var releaseCount = 0

    func hold(named name: String, onExpiration: @escaping @MainActor () -> Void) { holds.append(name) }
    func holdWithGrace(named name: String, for grace: Duration, onExpiration: @escaping @MainActor () -> Void) { holds.append(name) }
    func release() { releaseCount += 1 }
}

/// Lets a `@Sendable` observation or task callback report back into a test.
final class TestFlag: Sendable {
    private let state = Mutex(false)
    var value: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// Records what dictation did to the microphone without touching `AVAudioSession`.
@MainActor
final class StubVoiceRecorder: VoiceInputRecording {
    private(set) var didStop = false
    private(set) var didDeactivate = false

    func ensurePermission() async throws {}
    func activateSession() async throws {}
    func deactivateSession() async throws { didDeactivate = true }
    func start(output: PCM16CaptureOutput) async throws {
        output.receive(Data(repeating: 1, count: output.sampleRate / 10 * 2))
    }
    func stop() { didStop = true }
    func normalizedLevel() -> Float { 0 }
}

struct TemporaryDictationRecordings {
    let directory = FileManager.default.temporaryDirectory.appending(path: "dictation-recordings-\(UUID())")
    let store: DictationRecordingStore<ExecutionTarget>

    init() throws {
        store = DictationRecordingStore(
            directory: directory,
            retention: try DictationRecordingRetention(maximumCount: 5, maximumAge: .seconds(3_600))
        )
    }

    func save(owner: ExecutionTarget) async throws -> DictationRecording<ExecutionTarget> {
        let writer = try await store.startRecording(owner: owner, sampleRate: 16_000)
        writer.append(Data(repeating: 1, count: 3_200))
        return try await writer.finish()
    }

    func listedIDs() async throws -> Set<UUID> {
        Set(try await store.recordings().map(\.id))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

extension GatewayRoutes {
    static func isolated(_ host: GatewayHostConfiguration) -> GatewayRoutes {
        GatewayRoutes(host: host, directory: URL.temporaryDirectory.appending(path: "isolated-gateway-routes"),
                      relayStorage: MemoryGatewayCredentials(), policy: .isolated, observeLocalNetwork: { _ in })
    }
}

extension GatewaySpeechAccess {
    static let fixture = {
        let host = GatewayHostConfiguration(
            id: UUID(), name: "Speech test", hostname: "speech.example", port: 8787, authToken: "speech-test-token")
        return GatewaySpeechAccess(host: host, routes: .isolated(host))
    }()
}

struct StubTranscriber: TranscriptionService {
    let text: String

    func makeRealtimeTranscription(configuration: TranscriptionConfiguration) async throws -> RealtimeTranscription? { nil }

    @concurrent
    func transcribe(_ recording: DictationRecording<ExecutionTarget>, configuration: TranscriptionConfiguration) async throws -> String { text }
}
