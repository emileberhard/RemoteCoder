import DictationLibrary
import Foundation
import Observation
import SpeechKit

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
    @ObservationIgnored private var publicationTask: Task<Void, Never>?
    @ObservationIgnored private var publicationRequested = false
    @ObservationIgnored private var publicationGeneration: UInt64 = 0
    @ObservationIgnored private var settingsTask: Task<Void, Never>?
    @ObservationIgnored private var accountTask: Task<Void, Never>?
    @ObservationIgnored private var profileAccount: DictationAccountSession?
    @ObservationIgnored private var finalizationTask: Task<Void, Never>?
    @ObservationIgnored private var finalizationID: UUID?
    @ObservationIgnored private let finalize: @Sendable (DictationCaptureWriter) async throws -> Void
    @ObservationIgnored private var storeTask: Task<DictationLibraryStore, any Error>?

    init(defaults: UserDefaults, directory: URL,
         finalize: @escaping @Sendable (DictationCaptureWriter) async throws -> Void = { _ = try await $0.finish() }) {
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
            fallbackModel: configuration.model.libraryID, supportsCleanup: true,
            modelOptions: Dictionary(uniqueKeysWithValues: TranscriptionModel.allCases.map { ($0.libraryID, $0.libraryOptions) }))
        do {
            switch await store.profileState() {
            case .ready: break
            case .absent:
                status = "Set up your profile in WisprClone"
                return nil
            case .unverified, .unavailable: throw DictationLibraryError.accountUnavailable
            }
            guard let confirmedAccount = await store.accountSession() else { throw DictationLibraryError.accountUnavailable }
            account = confirmedAccount
            plan = try await store.makePlan(context: .chat, capabilities: capabilities)
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
        let previous = finalizationTask
        let id = UUID()
        finalizationID = id
        finalizationTask = Task(priority: .utility) {
            await previous?.value
            do {
                try await finalize(writer)
                status = "Saved on this device"
                requestPublication()
            } catch {
                status = "Recording retained for recovery: \(error.localizedDescription)"
            }
            if finalizationID == id { finalizationTask = nil }
        }
    }

    func finishPendingCaptures() async {
        await finalizationTask?.value
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
                try await store.validateAccountSession(account)
                guard let snapshot = try await store.refresh(), snapshot.accountIdentifier == account.accountIdentifier else {
                    throw DictationLibraryError.profileUnavailable
                }
                try await store.validateAccountSession(account)
                var value = snapshot.profile
                update(&value)
                try await store.saveProfile(value, session: account)
                try await store.validateAccountSession(account)
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
        let account = await store.accountSession()
        guard let capture = try await store.capture(id: id) else { return nil }
        guard let account else { throw DictationLibraryError.accountUnavailable }
        try await store.validateAccountSession(account)
        return (capture.plan, account)
    }

    func result(_ text: String, recordingID: UUID, plan: DictationPlan, account: DictationAccountSession?, model: String, access: GatewaySpeechAccess) async throws -> String {
        let store = try await store()
        let raw = DictationResultVersion(id: UUID(), captureID: recordingID, createdAt: .now,
            kind: .providerOutput, text: text, model: model, contextWasUsed: false, parentResultID: nil, plan: plan)
        if plan.archiveEnabled { try await store.addResult(raw) }
        if let account {
            try await store.validateAccountSession(account)
            if plan.archiveEnabled { try await store.validateCapture(id: recordingID) }
        }
        guard plan.cleanupEnabled else {
            requestPublication()
            if let account { try await store.validateAccountSession(account) }
            return text
        }
        let cleaned = try await DictationCleanup.clean(text: text, plan: plan, access: try await access.access(to: .gemini))
        if let account {
            try await store.validateAccountSession(account)
            if plan.archiveEnabled { try await store.validateCapture(id: recordingID) }
        }
        if plan.archiveEnabled, cleaned.kind != .providerOutput { try await store.addResult(DictationResultVersion(id: UUID(), captureID: recordingID, createdAt: .now,
            kind: cleaned.kind, text: cleaned.text, model: cleaned.model, contextWasUsed: cleaned.contextWasUsed, parentResultID: raw.id, plan: plan)) }
        requestPublication()
        if let account { try await store.validateAccountSession(account) }
        return cleaned.text
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
        guard isEnabled else { return }
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
            if self?.publicationGeneration == generation { self?.publicationTask = nil }
        }
    }

    private func performPublication() async {
        guard isEnabled else { return }
        do {
            let store = try await store()
            _ = try await store.recoverInterruptedCaptures()
            _ = try await store.refresh()
            let profile = await store.profileState()
            let account = await store.accountSession()
            if let account { try await store.validateAccountSession(account) }
            if case .ready(let snapshot) = profile, snapshot.accountIdentifier == account?.accountIdentifier {
                profileAccount = account
                self.profile = snapshot.profile
            } else { self.profile = nil }
            let pending = try await store.publishPending()
            unassignedCaptureCount = pending.unverifiedCaptureCount
            if let failure = pending.failures.first {
                status = "\(pending.failures.count) recordings need attention: \(failure.message)"
            } else if pending.heldCaptureCount > 0 {
                status = "\(pending.heldCaptureCount) recordings held for account reconciliation"
            } else if pending.pendingCaptureCount > 0 {
                status = "\(pending.pendingCaptureCount) recordings waiting to upload"
            } else if case .absent = profile {
                status = "Set up your profile in WisprClone"
            } else if case .ready(let snapshot) = profile, !snapshot.profile.archiveEnabled {
                status = "Shared settings active · original archiving off"
            } else {
                status = "Synced to iCloud"
            }
        } catch is CancellationError {
        } catch {
            status = "Saved on this device · upload pending: \(error.localizedDescription)"
        }
    }

    func failure(recordingID: UUID, plan: DictationPlan, error: any Error) async {
        do {
            try await store().addResult(DictationResultVersion(id: UUID(), captureID: recordingID, createdAt: .now,
                kind: .failure, text: String(reflecting: type(of: error)), model: plan.effectiveModel, contextWasUsed: false, parentResultID: nil, plan: plan))
            requestPublication()
        } catch {
            status = "Original retained · result could not be saved: \(error.localizedDescription)"
        }
    }

    func accountForConfirmation() async -> DictationAccountSession? {
        do {
            let store = try await store()
            _ = try await store.refresh()
            guard let account = await store.accountSession() else { throw DictationLibraryError.accountUnavailable }
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

    func accountEvents(validating account: DictationAccountSession) async throws -> AsyncStream<DictationAccountSession?> {
        let store = try await store()
        let events = await store.accountEvents()
        try await store.validateAccountSession(account)
        return events
    }

    func accountChanged() {
        profile = nil
        status = "iCloud account changed · recording retained for its original account"
    }

    private func store() async throws -> DictationLibraryStore {
        if let storeTask { return try await storeTask.value }
        let directory = directory
        let task = Task { try await Self.open(directory: directory) }
        storeTask = task
        do {
            let store = try await task.value
            accountTask = Task { [weak self] in
                for await session in await store.accountEvents() {
                    guard let self else { return }
                    if session != profileAccount { profile = nil; profileAccount = nil }
                }
            }
            return store
        }
        catch { storeTask = nil; throw error }
    }

    deinit { accountTask?.cancel(); settingsTask?.cancel() }

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
        case .openAIGPT4oMini: "openai/gpt-4o-mini-transcribe-2025-12-15/batch"
        case .openAIGPT4oTranscribe: "openai/gpt-4o-transcribe/batch"
        case .openAIWhisper1: "openai/whisper-1/batch"
        case .openAIRealtimeWhisper: "openai/gpt-realtime-whisper/realtime"
        case .openAIGPT4oTranscribeRealtime: "openai/gpt-4o-transcribe/realtime"
        case .openAIGPT4oMiniTranscribeRealtime: "openai/gpt-4o-mini-transcribe/realtime"
        case .gemini35Flash: "google/gemini-3.5-flash/batch"
        case .gemini35TranscribeSmart: "google/gemini-3.5-transcribe/batch"
        case .gemini35TranscribeVerbatim: "google/gemini-3.5-transcribe/batch?mode=verbatim"
        case .gemini35TranscribeLiveSmart: "google/gemini-3.5-transcribe-live/realtime"
        case .gemini35TranscribeLiveVerbatim: "google/gemini-3.5-transcribe-live/realtime?mode=verbatim"
        case .assemblyAIUniversal35Pro: "assemblyai/universal-3-5-pro+universal-2/batch"
        case .assemblyAIUniversal35ProRealtime: "assemblyai/universal-3-5-pro/realtime"
        case .azureMAITranscribe2: "azure/MAI-Transcribe-2/progressive"
        }
    }

    var libraryOptions: [String: String] {
        switch self {
        case .gemini35TranscribeSmart, .gemini35TranscribeLiveSmart: ["mode": "smart"]
        case .gemini35TranscribeVerbatim, .gemini35TranscribeLiveVerbatim: ["mode": "verbatim"]
        case .azureMAITranscribe2: ["transcribeStyle": "clean"]
        default: [:]
        }
    }

    var batchLibraryID: String {
        switch self {
        case .elevenLabsScribeV2Realtime: TranscriptionModel.elevenLabsScribeV2.libraryID
        case .openAIRealtimeWhisper: TranscriptionModel.openAIWhisper1.libraryID
        case .openAIGPT4oTranscribeRealtime: TranscriptionModel.openAIGPT4oTranscribe.libraryID
        case .openAIGPT4oMiniTranscribeRealtime: TranscriptionModel.openAIGPT4oMini.libraryID
        case .gemini35TranscribeLiveSmart: TranscriptionModel.gemini35TranscribeSmart.libraryID
        case .gemini35TranscribeLiveVerbatim: TranscriptionModel.gemini35TranscribeVerbatim.libraryID
        case .assemblyAIUniversal35ProRealtime: TranscriptionModel.assemblyAIUniversal35Pro.libraryID
        case .azureMAITranscribe2: "azure/MAI-Transcribe-2/batch"
        default: libraryID
        }
    }
}

extension TranscriptionConfiguration {
    init(plan: DictationPlan, local: TranscriptionConfiguration) throws {
        guard let model = TranscriptionModel.allCases.first(where: { $0.libraryID == plan.effectiveModel && $0.libraryOptions == plan.providerOptions }) else {
            throw DictationLibraryError.invalidConfiguration
        }
        self.init(model: model, language: local.language, customVocabulary: plan.dictionary, sharedLanguages: plan.languages)
    }
}
