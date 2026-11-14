import DictationLibrary
import Foundation
import Observation
import SpeechKit
import SpeakerRecognition

@MainActor
@Observable
final class SharedDictationLibrary {
    struct Capture {
        let id: UUID
        let writer: DictationCaptureWriter?
        let plan: DictationPlan
        let account: DictationAccountSession?
    }

    private(set) var status = "Not connected"
    private(set) var unassignedCaptureCount = 0
    private(set) var modelResolution: String?
    private(set) var profile: DictationProfile?
    private(set) var isSavingSettings = false
    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { requestPublication() } else { cancelPublication() }
        }
    }

    private static let enabledKey = "dictation.sharedLibrary.enabled"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let background: any BackgroundExecution
    @ObservationIgnored private var backgroundHeld = false
    @ObservationIgnored private var backgroundExpired = false
    @ObservationIgnored private var isInBackground = false
    @ObservationIgnored private var profileRefreshTask: Task<Void, Never>?
    @ObservationIgnored private let openStore: @Sendable (URL) async throws -> DictationLibraryStore
    @ObservationIgnored private var publicationTask: Task<Void, Never>?
    @ObservationIgnored private var publicationRequested = false
    @ObservationIgnored private var publicationGeneration: UInt64 = 0
    @ObservationIgnored private var settingsTask: Task<Void, Never>?
    @ObservationIgnored private var accountTask: Task<Void, Never>?
    @ObservationIgnored private var profileAccount: DictationAccountSession?
    @ObservationIgnored private var archiving: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var unsavedResults: [UUID: DictationResultVersion] = [:]
    @ObservationIgnored private let logger = AppLogger(category: "DictationLibrary")
    private var accountRevision = 0
    @ObservationIgnored private let finalize: @Sendable (DictationCaptureWriter) async throws -> Void
    @ObservationIgnored private var storeTask: Task<DictationLibraryStore, any Error>?

    init(defaults: UserDefaults, directory: URL, background: any BackgroundExecution,
         openStore: @escaping @Sendable (URL) async throws -> DictationLibraryStore = { try await SharedDictationLibrary.open(directory: $0) },
         finalize: @escaping @Sendable (DictationCaptureWriter) async throws -> Void = { _ = try await $0.finish() }) {
        self.background = background
        self.openStore = openStore
        self.finalize = finalize
        self.defaults = defaults
        self.directory = directory
        isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    func prepare(configuration: TranscriptionConfiguration) async throws -> Capture? {
        guard isEnabled else { return nil }
        let store: DictationLibraryStore
        do { store = try await self.store() }
        catch {
            status = "Original archive unavailable · local recovery only: \(error.localizedDescription)"
            return nil
        }
        modelResolution = nil
        let plan: DictationPlan
        var account: DictationAccountSession?
        let capabilities = try DictationCapabilities(models: Set(TranscriptionModel.allCases.map(\.libraryID)),
            fallbackModel: configuration.model.libraryID, supportsCleanup: false,
            modelOptions: Dictionary(uniqueKeysWithValues: TranscriptionModel.allCases.map { ($0.libraryID, $0.libraryOptions) }))
        do {
            switch await store.profileState() {
            case .ready: break
            case .absent:
                status = "Set up your profile in WisprClone"
                return nil
            case .unverified, .unavailable: throw DictationLibraryError.accountUnavailable
            }
            plan = try await store.makePlan(context: .chat, capabilities: capabilities)
            account = plan.accountSession
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            account = nil
            let profile = DictationProfile(archiveEnabled: true, preferredModel: configuration.model.libraryID,
                languages: configuration.languageHints, dictionary: [], cleanupEnabled: false,
                outputLanguage: nil, thinkingLevel: "minimal")
            plan = DictationPlan(unverifiedProfile: profile, context: .chat, capabilities: capabilities)
            status = "Library unavailable · new recordings held on this device: \(error.localizedDescription)"
        }
        if plan.usesFallbackModel {
            modelResolution = "WisprClone’s model is unavailable · using \(configuration.model.name)"
        }
        guard plan.archiveEnabled else {
            status = "Shared settings active · original archiving off"
            return Capture(id: UUID(), writer: nil, plan: plan, account: account)
        }
        do {
            let writer = try await store.beginCapture(plan: plan)
            return Capture(id: writer.id, writer: writer, plan: plan, account: account)
        } catch DictationLibraryError.capacityExceeded {
            status = "Library storage is full · this dictation uses local recovery only"
            return nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            status = "Original not archived · local recovery only: \(error.localizedDescription)"
            return nil
        }
    }

    func finish(_ capture: Capture) {
        guard let writer = capture.writer else { return }
        startArchiving { [self] in
            do {
                try await finalize(writer)
                status = unsavedResults.isEmpty ? "Saved on this device" : unsavedResultsStatus
                requestPublication()
            } catch DictationLibraryError.noAudio {
                logger.notice("dictation ended without audio capture=\(capture.id.uuidString)")
            } catch {
                status = "Recording retained for recovery: \(error.localizedDescription)"
            }
        }
    }

    func finishArchiving() async {
        while let task = archiving.values.first { await task.value }
    }

    private func startArchiving(_ work: @escaping @MainActor () async -> Void) {
        let id = UUID()
        holdBackgroundExecution()
        archiving[id] = Task(priority: .utility) { [self] in
            await work()
            archiving[id] = nil
            releaseBackgroundExecutionIfIdle()
        }
    }

    private func holdBackgroundExecution() {
        guard !backgroundHeld, !backgroundExpired else { return }
        backgroundHeld = true
        background.hold(named: "Save dictation library") { [weak self] in
            guard let self else { return }
            backgroundExpired = true
            cancelPublication()
            background.release()
            backgroundHeld = false
        }
    }

    private func releaseBackgroundExecutionIfIdle() {
        guard archiving.isEmpty, publicationTask == nil else { return }
        backgroundExpired = false
        guard backgroundHeld else { return }
        background.release()
        backgroundHeld = false
    }

    func applicationDidBecomeActive() {
        isInBackground = false
        backgroundExpired = false
        guard isEnabled, profileRefreshTask == nil else { return }
        profileRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { profileRefreshTask = nil }
            do { try await refreshProfile(in: store()) }
            catch is CancellationError { return }
            catch { status = "Shared settings unavailable: \(error.localizedDescription)" }
            guard !Task.isCancelled else { return }
            requestPublication()
        }
    }

    func applicationDidEnterBackground() {
        isInBackground = true
    }

    private func refreshProfile(in store: DictationLibraryStore) async throws {
        _ = try await store.refresh()
        let state = await store.profileState()
        let account = store.accountSession()
        if case .ready(let snapshot) = state, snapshot.accountIdentifier == account?.accountIdentifier {
            profileAccount = account
            profile = snapshot.profile
        } else { profile = nil; profileAccount = nil }
    }

    private func archive(_ version: DictationResultVersion) {
        guard version.plan.archiveEnabled else { requestPublication(); return }
        startArchiving { [self] in
            if await save(version) { requestPublication() }
        }
    }

    @discardableResult private func save(_ version: DictationResultVersion) async -> Bool {
        do {
            try await store().addResult(version)
            unsavedResults[version.id] = nil
            return true
        } catch {
            switch error {
            case DictationLibraryError.invalidCapture(_), DictationLibraryError.contentConflict(_):
                unsavedResults[version.id] = nil
                status = "Original retained · a transcript could not be saved to the library"
                logger.error("dictation result cannot be saved: \(String(reflecting: error))")
            default:
                if unsavedResults.updateValue(version, forKey: version.id) == nil {
                    logger.error("dictation result not saved; retained for retry: \(error.localizedDescription)")
                }
                status = unsavedResultsStatus
            }
        }
        return false
    }

    private var unsavedResultsStatus: String {
        "Original retained · \(unsavedResults.count) transcripts not yet saved to the library"
    }

    func model(fallback: TranscriptionModel) -> TranscriptionModel {
        guard isEnabled, let profile else { return fallback }
        return TranscriptionModel.allCases.first { $0.libraryID == profile.preferredModel } ?? fallback
    }

    func setModel(_ model: TranscriptionModel) {
        updateProfile { $0.preferredModel = model.libraryID }
    }

    func setLanguages(_ languages: [String]) {
        updateProfile { $0.languages = languages }
    }

    private func updateProfile(_ update: @escaping @Sendable (inout DictationProfile) -> Void) {
        guard isEnabled, !isSavingSettings, let account = profileAccount else { return }
        isSavingSettings = true
        settingsTask = Task {
            defer { isSavingSettings = false; settingsTask = nil }
            do {
                let store = try await store()
                try store.validateAccountSession(account)
                guard let snapshot = try await store.refresh(), snapshot.accountIdentifier == account.accountIdentifier else {
                    throw DictationLibraryError.profileUnavailable
                }
                try store.validateAccountSession(account)
                var value = snapshot.profile
                update(&value)
                try await store.saveProfile(value, session: account)
                try store.validateAccountSession(account)
                guard isEnabled else { return }
                profileAccount = account
                profile = value
            } catch {
                status = "Shared settings could not be saved: \(error.localizedDescription)"
            }
        }
    }

    func plan(for id: UUID) async throws -> (plan: DictationPlan, account: DictationAccountSession)? {
        let store = try await store()
        do { return try await verifiedPlan(for: id, store: store) }
        catch DictationLibraryError.accountUnavailable {
            _ = try await store.refresh()
            return try await verifiedPlan(for: id, store: store)
        }
    }

    private func verifiedPlan(for id: UUID, store: DictationLibraryStore) async throws -> (plan: DictationPlan, account: DictationAccountSession)? {
        let account = store.accountSession()
        guard let capture = try await store.capture(id: id) else { return nil }
        guard let account else { throw DictationLibraryError.accountUnavailable }
        try store.validateAccountSession(account)
        return (capture.plan, account)
    }

    func result(_ transcript: DictationTranscript, recordingID: UUID, plan: DictationPlan) -> DictationTranscript {
        let raw = DictationResultVersion(id: UUID(), captureID: recordingID, createdAt: .now,
            kind: .providerOutput, text: transcript.everyone, model: transcript.everyoneModel, contextWasUsed: false, parentResultID: nil, plan: plan)
        archive(raw)
        if transcript.removedVoices {
            archive(DictationResultVersion(id: UUID(), captureID: recordingID, createdAt: .now,
                kind: .providerOutput, text: transcript.text, model: transcript.model, contextWasUsed: false, parentResultID: raw.id, plan: plan))
        }
        return transcript
    }

    func publish() async {
        requestPublication()
        await publicationTask?.value
    }

    func cancelPublication() {
        publicationRequested = false
        publicationTask?.cancel()
    }

    func requestPublication() {
        guard isEnabled, !backgroundExpired else { return }
        holdBackgroundExecution()
        guard !backgroundExpired else { return }
        publicationRequested = true
        if let publicationTask, !publicationTask.isCancelled { return }
        let previous = publicationTask
        publicationGeneration &+= 1
        let generation = publicationGeneration
        publicationTask = Task { [weak self] in
            await previous?.value
            while let self, self.publicationGeneration == generation, self.publicationRequested, !Task.isCancelled {
                self.publicationRequested = false
                await self.performPublication()
            }
            if self?.publicationGeneration == generation {
                self?.publicationTask = nil
                self?.releaseBackgroundExecutionIfIdle()
            }
        }
    }

    private func performPublication() async {
        guard isEnabled else { return }
        let started = ContinuousClock.now
        var before: DictationPublicationStatus?
        var after: DictationPublicationStatus?
        var stopped: (any Error)?
        defer {
            logPublication(started: started, before: before, after: after, error: stopped)
        }
        do {
            let store = try await store()
            if store.accountSession() == nil { try await refreshProfile(in: store) }
            before = try await store.status()
            for version in unsavedResults.values { await save(version) }
            let pending = try await store.publishPending()
            after = pending
            unassignedCaptureCount = pending.unverifiedCaptureCount
            if !unsavedResults.isEmpty {
                status = unsavedResultsStatus
            } else if let failure = pending.failures.first {
                status = "\(pending.failures.count) recordings need attention: \(failure.error.localizedDescription)"
            } else if pending.heldCaptureCount > 0 {
                status = "\(pending.heldCaptureCount) recordings held for account reconciliation"
            } else if pending.pendingCaptureCount > 0 {
                status = "\(pending.pendingCaptureCount) recordings waiting to upload"
            } else if case .absent = await store.profileState() {
                status = "Set up your profile in WisprClone"
            } else if let profile, !profile.archiveEnabled {
                status = "Shared settings active · original archiving off"
            } else {
                status = "Synced to iCloud"
            }
        } catch {
            stopped = error
            if let storeTask, let store = try? await storeTask.value { after = try? await store.status() }
            if !(error is CancellationError) {
                status = unsavedResults.isEmpty ? "Saved on this device · upload pending: \(error.localizedDescription)" : unsavedResultsStatus
            }
        }
    }

    private func logPublication(started: ContinuousClock.Instant, before: DictationPublicationStatus?, after: DictationPublicationStatus?, error: (any Error)?) {
        guard error != nil || (before?.pendingCaptureCount ?? 0) > 0 || before != after || !(after?.failures.isEmpty ?? true) else { return }
        let elapsed = started.duration(to: .now)
        let milliseconds = elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        let outcome = error.map { $0 is CancellationError ? "cancelled" : "failed" } ?? ((after?.failures.isEmpty ?? true) ? "completed" : "capture_failures")
        let failures = (after?.failures ?? before?.failures ?? []).prefix(3).map {
            "\($0.captureID.uuidString):\(Self.diagnostic($0.error))"
        }.joined(separator: ",")
        logger.notice("publication background=\(isInBackground) duration_ms=\(milliseconds) pending_before=\(before.map { String($0.pendingCaptureCount) } ?? "unknown") pending_after=\(after.map { String($0.pendingCaptureCount) } ?? "unknown") held=\(after.map { String($0.heldCaptureCount) } ?? "unknown") outcome=\(outcome) error=\(error.map(Self.diagnostic) ?? "none") failures=[\(failures)]")
    }

    private static func diagnostic(_ error: any Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? DictationLibraryError {
            switch error {
            case .cloudFailure(let domain, let code): return "cloud_failure:\(domain):\(code)"
            case .storageFailure(let domain, let code): return "storage_failure:\(domain):\(code)"
            default: return Mirror(reflecting: error).children.first?.label ?? String(describing: error)
            }
        }
        let value = error as NSError
        let domain = [NSCocoaErrorDomain, NSURLErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain].contains(value.domain) ? value.domain : String(reflecting: type(of: error))
        return "\(domain):\(value.code)"
    }

    func failure(recordingID: UUID, plan: DictationPlan, error: any Error) {
        archive(DictationResultVersion(id: UUID(), captureID: recordingID, createdAt: .now,
            kind: .failure, text: String(reflecting: type(of: error)), model: plan.effectiveModel, contextWasUsed: false, parentResultID: nil, plan: plan))
    }

    func accountForConfirmation() async -> DictationAccountSession? {
        do {
            let store = try await store()
            _ = try await store.refresh()
            guard let account = store.accountSession() else { throw DictationLibraryError.accountUnavailable }
            return account
        } catch {
            status = "Local audio retained: \(error.localizedDescription)"
            return nil
        }
    }

    func freeUploadedLocalAudio(account: DictationAccountSession) async {
        do {
            let released = try await store().releasePublishedOriginals(finishedBefore: .now, session: account)
            status = "Freed \(released.releasedCount) uploaded originals · unpublished audio retained"
        } catch {
            status = "Local audio retained: \(error.localizedDescription)"
        }
    }

    func assignUnownedCaptures(account: DictationAccountSession) async {
        do {
            let store = try await store()
            for held in try await store.heldCaptures() where held.reason == .unverifiedPlan {
                try await store.reconcileHeldCapture(id: held.capture.id, session: account)
            }
            await publish()
        } catch {
            status = "Recordings remain held: \(error.localizedDescription)"
        }
    }

    func validateAccount(_ account: DictationAccountSession) async throws {
        try await store().validateAccountSession(account)
    }

    func localVoiceHistory() async throws -> DictationVoiceHistory? {
        guard isEnabled else { return nil }
        let store = try await store()
        if store.accountSession() == nil { _ = try await store.refresh() }
        guard let account = store.accountSession() else { throw DictationLibraryError.accountUnavailable }
        let entries = try await store.entries()
        try store.validateAccountSession(account)
        return DictationVoiceHistory(recordings: entries.compactMap { entry in
            guard let url = entry.originalURL, let finished = entry.capture.finishedAt else { return nil }
            return VoiceHistoryRecording(url: url, startedAt: entry.capture.startedAt, finishedAt: finished)
        }, validate: { try await self.validateAccount(account) })
    }

    func waitForAccountChange(from account: DictationAccountSession) async throws {
        let store = try await store()
        for await _ in Observations({ @MainActor [self] in accountRevision }) where store.accountSession() != account { return }
        throw CancellationError()
    }

    func accountChanged() {
        profile = nil
        status = "iCloud account changed · recording retained for its original account"
    }

    private func store() async throws -> DictationLibraryStore {
        if let storeTask { return try await storeTask.value }
        let directory = directory
        let task = Task {
            let store = try await openStore(directory)
            await followAccount(of: store)
            return store
        }
        storeTask = task
        do { return try await task.value }
        catch { storeTask = nil; throw error }
    }

    private func followAccount(of store: DictationLibraryStore) async {
        let sessions = await store.accountEvents()
        accountTask = Task { [weak self] in
            for await session in sessions {
                guard let self else { return }
                accountRevision &+= 1
                if session != profileAccount { profile = nil; profileAccount = nil }
            }
        }
    }

    deinit { accountTask?.cancel(); settingsTask?.cancel(); profileRefreshTask?.cancel() }

    @concurrent private static func open(directory: URL) async throws -> DictationLibraryStore {
        guard let container = Bundle.main.object(forInfoDictionaryKey: "RemoteCoderDictationContainer") as? String,
              !container.isEmpty, !container.contains("$(") else {
            throw CocoaError(.coderValueNotFound)
        }
        return try DictationLibraryStore(directory: directory, source: "RemoteCoder",
                                        capacityBytes: 536_870_912, containerIdentifier: container)
    }
}

extension TranscriptionModel {
    var libraryID: String {
        switch self {
        case .elevenLabsScribeV2Realtime: "elevenlabs/scribe_v2_realtime/realtime"
        case .elevenLabsScribeV2: "elevenlabs/scribe_v2/batch"
        case .assemblyAIUniversal35Pro: "assemblyai/universal-3-5-pro+universal-2/batch"
        case .assemblyAIUniversal35ProRealtime: "assemblyai/universal-3-5-pro/realtime"
        case .azureMAITranscribe2: "azure/MAI-Transcribe-2/batch"
        }
    }

    var libraryOptions: [String: String] {
        switch self {
        case .azureMAITranscribe2: ["transcribeStyle": "clean"]
        default: [:]
        }
    }

    var batchLibraryID: String {
        switch self {
        case .elevenLabsScribeV2Realtime: TranscriptionModel.elevenLabsScribeV2.libraryID
        case .assemblyAIUniversal35ProRealtime: TranscriptionModel.assemblyAIUniversal35Pro.libraryID
        case .azureMAITranscribe2: "azure/MAI-Transcribe-2/batch"
        default: libraryID
        }
    }
}

extension TranscriptionConfiguration {
    init(plan: DictationPlan, local: TranscriptionConfiguration) throws {
        let modelID = plan.effectiveModel == "azure/MAI-Transcribe-2/progressive"
            ? TranscriptionModel.azureMAITranscribe2.libraryID : plan.effectiveModel
        guard let model = TranscriptionModel.allCases.first(where: { $0.libraryID == modelID && $0.libraryOptions == plan.providerOptions }) else {
            throw DictationLibraryError.invalidConfiguration
        }
        self.init(model: model, language: local.language, customVocabulary: plan.dictionary, sharedLanguages: plan.languages,
                  voiceChoice: local.voiceChoice)
    }
}
