import Foundation
import OSLog

/// Owns acknowledged host preferences and a durable outbox of local edits.
/// Only its sync task sends mutations; a failed acknowledgement is retried with
/// the same mutation ID, never as a replacement of the whole remote map.
actor ConversationMetadataService {
    private let remote: any ConversationMetadataRemote
    private let store: ConversationMetadataStore
    private let logger = Logger(subsystem: "RemoteCoder", category: "CodexMetadata")
    private var document = SessionMetadataLocalState()
    private var hasLoaded = false
    private var loadTask: (id: UUID, task: Task<SessionMetadataLocalState, Error>)?
    private var revision: UInt64 = 0
    private var savedRevision: UInt64 = 0
    private var writing: (id: UUID, task: Task<Void, Error>)?
    private var syncTask: Task<Void, Never>?
    private var syncRequested = false
    private var isRetired = false
    private var settingsObservationRevision: UInt64 = 0
    private(set) var status = SessionMetadataStatus()
    private var observers: [UUID: AsyncStream<SessionMetadataStatus>.Continuation] = [:]

    init(remote: any ConversationMetadataRemote, store: ConversationMetadataStore) {
        self.remote = remote
        self.store = store
    }

    func statuses() -> AsyncStream<SessionMetadataStatus> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            guard !isRetired else { continuation.finish(); return }
            let id = UUID()
            observers[id] = continuation
            continuation.yield(status)
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func publishStatus() { for observer in observers.values { observer.yield(status) } }
    private func failed(_ error: any Error) {
        status.error = "Conversation settings could not be synchronized: \(error.localizedDescription)"
        logger.notice("\(self.status.error ?? "", privacy: .public)")
        publishStatus()
    }

    func bootstrap() async {
        do { try await load(); syncInBackground() } catch { failed(error) }
    }

    func syncInBackground() {
        guard !isRetired else { return }
        syncRequested = true
        guard syncTask == nil else { return }
        syncTask = Task { await performSync() }
    }

    func sync() async {
        syncInBackground()
        await syncTask?.value
    }

    func metadata(for sessionID: String) async -> ConversationMetadata? {
        do { try await load() }
        catch { failed(error); return nil }
        if document.pending[sessionID] == nil, document.observed?[sessionID] == nil, document.invalidated?.contains(sessionID) == true {
            await sync()
            guard document.invalidated?.contains(sessionID) != true else { return nil }
        }
        if let pending = document.pending[sessionID] { return pending.metadata }
        let preference = document.acknowledged[sessionID] ?? document.legacy?[sessionID]
        guard var observed = document.observed?[sessionID]?.metadata else { return preference }
        observed.fastModeEnabled = preference?.fastModeEnabled
        return observed
    }

    func observeSettings(_ notification: CodexAppServerV2.ThreadSettingsUpdatedNotification, observedAt: Date) async {
        guard !isRetired else { return }
        do {
            try await load()
            guard !isRetired else { return }
            settingsObservationRevision &+= 1
            let settings = notification.threadSettings
            let reasoning = settings.effort.map { "effort-\($0.rawValue)" } ?? "automatic"
            let observed = ConversationMetadata(sessionID: notification.threadId, modelID: settings.model,
                reasoningSelectionID: reasoning, fastModeEnabled: settings.fastModeSelection, updatedAt: observedAt)
            let acknowledgedRevision = document.acknowledged[notification.threadId]?.serverRevision
            if document.observed?[notification.threadId]?.metadata.selection != observed.selection
                || document.observed?[notification.threadId]?.acknowledgedRevision != acknowledgedRevision {
                var observations = document.observed ?? [:]
                observations[notification.threadId] = SessionMetadataObservation(metadata: observed,
                    acknowledgedRevision: acknowledgedRevision)
                document.observed = observations
                revision += 1
            }
            try await persist()
        } catch { failed(error) }
    }

    func upsert(sessionID: String, modelID: String, reasoningSelectionID: String, fastModeEnabled: Bool?,
                source: ConversationMetadata.Source) async {
        guard !isRetired else { return }
        do {
            try await load()
            guard !isRetired else { return }
            let rememberedFastMode = document.pending[sessionID]?.metadata.fastModeEnabled
                ?? document.acknowledged[sessionID]?.fastModeEnabled
                ?? document.legacy?[sessionID]?.fastModeEnabled
            let selection = ConversationMetadataSelection(sessionID: sessionID,
                modelID: modelID.trimmingCharacters(in: .whitespacesAndNewlines),
                reasoningSelectionID: reasoningSelectionID.trimmingCharacters(in: .whitespacesAndNewlines),
                fastModeEnabled: fastModeEnabled ?? rememberedFastMode, source: source)
            guard !selection.modelID.isEmpty, !selection.reasoningSelectionID.isEmpty else { return }
            if document.pending[sessionID]?.mutation.selection == selection {
                try await persist()
                syncInBackground()
                return
            }
            if document.pending[sessionID] == nil, document.observed?[sessionID] == nil,
               document.invalidated?.contains(sessionID) != true,
               document.acknowledged[sessionID]?.selection == selection { return }
            document.pending[sessionID] = SessionMetadataPending(mutation: ConversationMetadataMutation(selection: selection,
                expectedRevision: document.acknowledged[sessionID]?.serverRevision ?? 0, mutationID: UUID().uuidString), createdAt: .now)
            status.conflicts.remove(sessionID)
            revision += 1
            try await persist()
            syncInBackground()
        } catch { failed(error) }
    }

    /// Only an explicit user decision rebases a conflicting edit onto someone
    /// else's newer revision. Merely reconnecting never makes that decision.
    func resolveConflict(sessionID: String, keepLocal: Bool) async {
        guard !isRetired, status.conflicts.contains(sessionID) else { return }
        if keepLocal, let pending = document.pending[sessionID] {
            document.pending[sessionID] = SessionMetadataPending(mutation: ConversationMetadataMutation(selection: pending.mutation.selection,
                expectedRevision: document.acknowledged[sessionID]?.serverRevision ?? 0, mutationID: UUID().uuidString), createdAt: .now)
        } else {
            document.pending[sessionID] = nil
            document.observed?[sessionID] = nil
        }
        status.conflicts.remove(sessionID)
        revision += 1
        publishStatus()
        do { try await persist(); syncInBackground() } catch { failed(error) }
    }

    func retire() async {
        isRetired = true
        syncTask?.cancel()
        await syncTask?.value
        _ = await loadTask?.task.result
        _ = await writing?.task.result
        if hasLoaded, revision > savedRevision {
            do { try await persist() } catch { failed(error) }
        }
        for observer in observers.values { observer.finish() }
        observers.removeAll()
    }

    private func load() async throws {
        guard !hasLoaded else { return }
        let operation: (id: UUID, task: Task<SessionMetadataLocalState, Error>)
        if let loadTask { operation = loadTask }
        else {
            operation = (UUID(), Task { [store] in try await store.load() })
            loadTask = operation
        }
        do {
            let loaded = try await operation.task.value
            guard !hasLoaded else { return }
            document = loaded
            hasLoaded = true
            if loadTask?.id == operation.id { loadTask = nil }
        } catch {
            if loadTask?.id == operation.id { loadTask = nil }
            throw error
        }
    }

    private func persist() async throws {
        guard hasLoaded else { return }
        while savedRevision < revision {
            let operation: (id: UUID, task: Task<Void, Error>)
            if let writing { operation = writing }
            else {
                operation = (UUID(), Task { try await savePendingChanges() })
                writing = operation
            }
            do {
                try await operation.task.value
                if writing?.id == operation.id { writing = nil }
            } catch {
                if writing?.id == operation.id { writing = nil }
                throw error
            }
        }
    }

    private func savePendingChanges() async throws {
        while savedRevision < revision {
            let capturedRevision = revision
            try await store.save(document)
            savedRevision = capturedRevision
        }
    }

    private func performSync() async {
        defer { syncTask = nil }
        while syncRequested, !isRetired, !Task.isCancelled {
            syncRequested = false
            do {
                try await load()
                let observedSettings = settingsObservationRevision
                let received = try await remote.fetchRemoteMetadata()
                try Task.checkCancellation()
                guard !isRetired else { return }
                let previous = document
                if let legacy = document.legacy {
                    for (id, entry) in legacy where document.pending[id] == nil
                        && document.invalidated?.contains(id) != true && document.observed?[id] == nil
                        && received[id]?.selection != entry.selection {
                        document.pending[id] = SessionMetadataPending(mutation: ConversationMetadataMutation(selection: entry.selection,
                            expectedRevision: entry.serverRevision ?? 0, mutationID: UUID().uuidString), createdAt: entry.updatedAt)
                    }
                    document.legacy = nil
                }
                document.acknowledged = received
                if observedSettings == settingsObservationRevision {
                    document.invalidated = nil
                    if var observations = document.observed {
                        for (id, var observed) in observations {
                            guard let current = received[id] else { continue }
                            if let baseline = observed.acknowledgedRevision, let revision = current.serverRevision,
                               revision > baseline {
                                observations[id] = nil
                            } else if current.modelID == observed.metadata.modelID
                                && current.reasoningSelectionID == observed.metadata.reasoningSelectionID
                                && current.fastModeEnabled == observed.metadata.fastModeEnabled {
                                observations[id] = nil
                            } else if observed.acknowledgedRevision == nil, let revision = current.serverRevision {
                                observed.acknowledgedRevision = revision
                                observations[id] = observed
                            }
                        }
                        document.observed = observations
                    }
                }
                if document != previous { revision += 1 }
                try await persist()
                // Snapshot identifiers, not values. A newer local edit can arrive
                // at any await and must not be acknowledged by an older response.
                for id in document.pending.keys.sorted() {
                    try Task.checkCancellation()
                    guard !isRetired else { return }
                    guard let pending = document.pending[id], !status.conflicts.contains(id) else { continue }
                    do {
                        let observed = document.observed?[id]
                        let applied = try await remote.updateRemoteMetadata(pending.mutation)
                        guard !isRetired else { return }
                        document.acknowledged[id] = applied
                        if document.observed?[id] == observed { document.observed?[id] = nil }
                        if document.pending[id]?.mutation.mutationID == pending.mutation.mutationID {
                            document.pending[id] = nil
                        } else if document.pending[id]?.mutation.expectedRevision == pending.mutation.expectedRevision {
                            // Rebase only over this owner's successful predecessor.
                            document.pending[id]?.mutation.expectedRevision = applied.serverRevision ?? 0
                            syncRequested = true
                        }
                        revision += 1
                        try await persist()
                    } catch let conflict as GatewayRPCFailure where conflict.kind == .metadataConflict {
                        if let current = conflict.currentMetadata { document.acknowledged[id] = current }
                        else { document.acknowledged[id] = nil }
                        if document.pending[id]?.mutation.selection == conflict.currentMetadata?.selection {
                            document.pending[id] = nil
                        } else { status.conflicts.insert(id) }
                        revision += 1
                        try await persist()
                    }
                }
                status.error = nil
                publishStatus()
            } catch is CancellationError { return }
            catch { failed(error); return }
        }
    }
}
