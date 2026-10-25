import Foundation
import Observation
import OSLog
import SwiftData

/// Owns the editable drafts and their persistence for one gateway host.
@MainActor
@Observable
final class ComposerDraftStore {
    enum Destination: Hashable, Sendable {
        case newChat(UUID)
        case thread(String)
        case conversation(UUID)

        var key: String {
            switch self {
            case .newChat(let id): "\(Self.newChatPrefix)\(id)"
            case .thread(let id): "thread:\(id)"
            case .conversation(let id): "conversation:\(id)"
            }
        }

        static let newChatPrefix = "new-chat:"

        static func isNewChat(key: String) -> Bool {
            key.hasPrefix(newChatPrefix)
        }

        static func newChatID(for key: String) -> UUID? {
            guard isNewChat(key: key) else { return nil }
            return UUID(uuidString: String(key.dropFirst(newChatPrefix.count)))
        }

        static func threadID(for key: String) -> String? {
            let prefix = "thread:"
            guard key.hasPrefix(prefix) else { return nil }
            let id = String(key.dropFirst(prefix.count))
            return id.isEmpty ? nil : id
        }
    }

    struct SubmissionReservation: Hashable {
        let draftID: UUID
        let revision: Int
    }

    struct OutgoingMessage {
        fileprivate let id = UUID()
        fileprivate let draft: ComposerDraft
        fileprivate let content: ComposerDocumentContent
        fileprivate let attachments: [ComposerAttachment]
    }

    @ObservationIgnored private var pendingDictations: Set<UUID> = []
    @ObservationIgnored private var dictationsDrained: CheckedContinuation<Void, Never>?

    private enum DictationEditError: LocalizedError {
        case alreadyPending
        case pendingCapacity
        var errorDescription: String? {
            switch self {
            case .alreadyPending: "This dictation is already being added to its draft."
            case .pendingCapacity: "Save the pending draft changes before adding more dictation."
            }
        }
    }

    @ObservationIgnored private var submissions: Set<SubmissionReservation> = []
    @ObservationIgnored private var outgoing: [UUID: [OutgoingMessage]] = [:]
    @ObservationIgnored private var unsent: Set<UUID> = []
    private(set) var acceptsInput = true
    @ObservationIgnored private var submissionsDrained: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var submissionDrain: Task<Void, Never>?

    /// Admission is synchronous with reading the draft. Unrelated drafts and a
    /// genuinely newer revision remain independent while persistence suspends.
    func reserveSubmission(of draft: ComposerDraft) -> SubmissionReservation? {
        guard acceptsInput, acceptsChanges() else { return nil }
        let reservation = SubmissionReservation(draftID: draft.id, revision: draft.revision)
        return submissions.insert(reservation).inserted ? reservation : nil
    }

    func releaseSubmission(_ reservation: SubmissionReservation) {
        submissions.remove(reservation)
        if submissions.isEmpty { submissionsDrained?.resume(); submissionsDrained = nil }
    }

    func quiesce() { acceptsInput = false }

    func drainSubmissions() async {
        while !submissions.isEmpty {
            let task = submissionDrain ?? Task {
                await withCheckedContinuation { continuation in
                    if submissions.isEmpty { continuation.resume() }
                    else { submissionsDrained = continuation }
                }
            }
            submissionDrain = task
            await task.value
            if submissionDrain == task { submissionDrain = nil }
        }
    }

    func resume() { acceptsInput = true }

    private(set) var errorMessage: String?
    private(set) var unsentDrafts: [UnsentDraftSummary] = []
    private var discardingDrafts: Set<UUID> = []
    @ObservationIgnored private var discards: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var unsentDraftsRefresh: Task<Void, Never>?
    @ObservationIgnored private let logger = AppLogger(category: "ComposerDrafts")
    private var destinationErrors: [String: String] = [:]
    @ObservationIgnored private var destinationErrorOrder: [String] = []
    @ObservationIgnored private let directory: URL
    private final class WeakDraft {
        weak var value: ComposerDraft?
        init(_ value: ComposerDraft) { self.value = value }
    }

    private final class WeakDocument {
        weak var value: ComposerDocument?
        init(_ value: ComposerDocument) { self.value = value }
    }
    @ObservationIgnored private var documents: [UUID: WeakDocument] = [:]

    private static let capacity = 32
    @ObservationIgnored private var persistence: ComposerDraftPersistence?
    @ObservationIgnored private var opening: (id: UUID, task: Task<ComposerDraftPersistence, Error>)?
    @ObservationIgnored private var loading: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var cached: [String: ComposerDraft] = [:]
    @ObservationIgnored private var references: [String: WeakDraft] = [:]
    @ObservationIgnored private var recency: [String] = []
    @ObservationIgnored private var writing: Task<Bool, Never>?
    @ObservationIgnored private var pendingReceipts: [UUID: ComposerDraftReceipt] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var pendingDocuments: [UUID: ComposerDraft] = [:]
    private enum State { case active, retiring, recovery, retired }
    @ObservationIgnored private var state = State.active
    @ObservationIgnored private var retirementTask: Task<Bool, Never>?

    init(directory: URL) {
        self.directory = directory
    }

    var listedUnsentDrafts: [UnsentDraftSummary] {
        discardingDrafts.isEmpty ? unsentDrafts : unsentDrafts.filter { !discardingDrafts.contains($0.id) }
    }

    func hasContent(_ draft: ComposerDraft) -> Bool {
        outgoing[draft.id] != nil || !draft.attachments.isEmpty || document(for: draft).hasContent
    }

    func setNewChatSetup(_ setup: NewChatSetup, in draft: ComposerDraft) {
        guard acceptsInput, acceptsChanges(), Destination.isNewChat(key: draft.destination), draft.newChat != setup else { return }
        draft.newChat = setup
        markDirty(draft)
    }

    func discardUnsentDraft(_ id: UUID, after undoWindow: Duration,
                            releasing release: @escaping @MainActor (ComposerDraft) -> Void) {
        guard acceptsChanges(), discards[id] == nil else { return }
        discardingDrafts.insert(id)
        discards[id] = Task { [weak self] in
            do { try await Task.sleep(for: undoWindow) } catch { return }
            await self?.deleteUnsentDraft(id, releasing: release)
        }
    }

    func isDiscarding(_ id: UUID) -> Bool {
        discardingDrafts.contains(id)
    }

    func restoreUnsentDraft(_ id: UUID) {
        discards.removeValue(forKey: id)?.cancel()
        discardingDrafts.remove(id)
    }

    private func deleteUnsentDraft(_ id: UUID, releasing release: (ComposerDraft) -> Void) async {
        let destination = Destination.newChat(id)
        do {
            let backing = try await open()
            _ = await flush()
            guard !Task.isCancelled else { return }
            let draft = cachedDraft(for: destination)
            if let draft {
                draft.isDiscarded = true
                pendingDocuments[draft.id] = nil
                pendingReceipts = pendingReceipts.filter { $0.value.draftID != draft.id }
                forget(destination.key)
            }
            try await backing.delete(destination: destination.key)
            unsentDrafts.removeAll { $0.id == id }
            if let draft { release(draft) }
        } catch {
            logger.error("unsent draft discard failed: \(error.localizedDescription)")
        }
        guard !Task.isCancelled else { return }
        discards[id] = nil
        discardingDrafts.remove(id)
    }

    private func refreshUnsentDrafts() {
        guard state == .active else { return }
        unsentDraftsRefresh?.cancel()
        unsentDraftsRefresh = Task { [weak self] in
            guard let self else { return }
            do {
                let drafts = try await open().unsentDrafts()
                guard !Task.isCancelled, state == .active, unsentDrafts != drafts else { return }
                unsentDrafts = drafts
            } catch {
                logger.error("unsent drafts could not be listed: \(error.localizedDescription)")
            }
        }
    }

    func destinationError(for destination: Destination) -> String? {
        destinationErrors[destination.key]
    }

    private func recordDestinationError(_ message: String, key: String) {
        destinationErrors[key] = message
        destinationErrorOrder.removeAll { $0 == key }
        destinationErrorOrder.append(key)
        while destinationErrorOrder.count > Self.capacity, let oldest = destinationErrorOrder.first {
            destinationErrors[oldest] = nil
            destinationErrorOrder.removeFirst()
        }
    }

    private func clearDestinationError(_ key: String) {
        destinationErrors[key] = nil
        destinationErrorOrder.removeAll { $0 == key }
    }

    func cachedDraft(for destination: Destination) -> ComposerDraft? {
        let draft = cached[destination.key] ?? references[destination.key]?.value
        return draft?.destination == destination.key ? draft : nil
    }

    /// The draft saved under this destination, created empty when there is
    /// none. The caller owns which draft is showing.
    func draft(for destination: Destination) async -> ComposerDraft? {
        guard acceptsChanges() else {
            recordDestinationError(ComposerDraftPersistence.Failure.retired.localizedDescription, key: destination.key)
            return nil
        }
        guard acceptsInput else { return cachedDraft(for: destination) }
        if let draft = cachedDraft(for: destination) { remember(draft); return draft }
        if let operation = loading[destination.key] {
            await operation.value
            guard acceptsChanges() else { return nil }
            return cachedDraft(for: destination)
        }
        guard loading.count + pendingDocuments.count < Self.capacity else {
            recordDestinationError("Could not open another draft while changes remain unsaved. Retry saving your drafts.", key: destination.key)
            return nil
        }
        let operation = Task { await loadDraft(destination) }
        loading[destination.key] = operation
        await operation.value
        guard acceptsChanges() else { return nil }
        return cachedDraft(for: destination)
    }

    private func loadDraft(_ destination: Destination) async {
        defer { loading[destination.key] = nil }
        do {
            let backing = try await open()
            if let writing { _ = await writing.value }
            let saved = try await backing.load(destination: destination.key)
            if cachedDraft(for: destination) != nil { return }
            let draft = ComposerDraft(destination: destination.key)
            if let saved {
                draft.id = saved.snapshot.id
                draft.revision = saved.snapshot.revision
                draft.documentContent = saved.snapshot.content
                draft.attachments = saved.snapshot.attachments
                draft.text = saved.text
                draft.modifiedAt = saved.snapshot.modifiedAt
                draft.newChat = saved.snapshot.newChat
            }
            remember(draft)
            _ = document(for: draft)
            if saved == nil || saved?.needsSave == true { pendingDocuments[draft.id] = draft }
            clearDestinationError(destination.key)
        } catch { recordDestinationError("Could not load this draft: \(error.localizedDescription)", key: destination.key) }
    }

    private func forget(_ key: String) {
        cached[key] = nil
        references[key] = nil
        recency.removeAll { $0 == key }
    }

    private func remember(_ draft: ComposerDraft) {
        let key = draft.destination
        references = references.filter { $0.value.value != nil && $0.value.value?.destination == $0.key }
        references[key] = WeakDraft(draft)
        cached = cached.filter { $0.value.destination == $0.key }
        recency.removeAll { cached[$0] == nil }
        cached[key] = draft
        recency.removeAll { $0 == key }
        recency.append(key)
        while cached.count > Self.capacity, let oldest = recency.first {
            cached[oldest] = nil
            recency.removeFirst()
        }
    }

    func document(for draft: ComposerDraft) -> ComposerDocument {
        if let document = draft.document { return document }
        let content = Self.persistedContent(draft)
        let document = ComposerDocument(content: content) { [weak self, weak draft] in
            guard let self, let draft else { return }
            self.changed(draft)
        }
        draft.document = document
        documents = documents.filter { $0.value.value != nil }
        documents[document.id] = WeakDocument(document)
        if state != .active { document.retire(); return document }
        if draft.documentContent == nil { pendingDocuments[draft.id] = draft }
        if draft.attachments.contains(where: { $0.text != nil }) {
            draft.attachments.removeAll { $0.text != nil }
        }
        return document
    }

    func setText(_ text: String, in draft: ComposerDraft) {
        guard acceptsInput, acceptsChanges() else { return }
        let document = document(for: draft)
        document.edit(.replaceAll(.init(runs: text.isEmpty ? [] : [.text(text)])))
    }

    func setContent(_ content: ComposerDocumentContent, in draft: ComposerDraft) {
        guard acceptsInput, acceptsChanges() else { return }
        applyContent(content, in: draft)
    }

    private func applyContent(_ content: ComposerDocumentContent, in draft: ComposerDraft) {
        let document = document(for: draft)
        document.edit(.replaceAll(content))
    }

    func setAttachments(_ attachments: [ComposerAttachment], in draft: ComposerDraft) {
        guard acceptsInput, acceptsChanges() else { return }
        let pasted = attachments.compactMap { attachment -> ComposerDocumentContent.Run? in
            guard let text = attachment.text else { return nil }
            return .paste(.init(id: attachment.id, text: text))
        }
        if !pasted.isEmpty { document(for: draft).edit(.insert(.init(runs: pasted))) }
        let filesAndImages = attachments.filter { $0.text == nil }
        guard draft.attachments != filesAndImages else { return }
        draft.attachments = filesAndImages
        changed(draft)
    }

    func updatePastedText(_ text: String, attachmentID: UUID, in draft: ComposerDraft) {
        guard acceptsInput, acceptsChanges() else { return }
        document(for: draft).edit(.updatePaste(attachmentID, text))
    }

    func appendText(_ text: String, to draft: ComposerDraft) {
        guard acceptsInput, acceptsChanges() else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let document = document(for: draft)
        document.edit(.dictation(text))
    }

    func appendDictation(_ text: String, recordingID: UUID, to draft: ComposerDraft) async throws {
        try requireActive()
        guard pendingReceipts[recordingID] == nil else { return }
        guard pendingReceipts.count + pendingDictations.count < Self.capacity else { throw DictationEditError.pendingCapacity }
        guard pendingDictations.insert(recordingID).inserted else { throw DictationEditError.alreadyPending }
        defer {
            pendingDictations.remove(recordingID)
            if pendingDictations.isEmpty { dictationsDrained?.resume(); dictationsDrained = nil }
        }
        let backing = try await open()
        try requireActive()
        guard try await !backing.hasSavedReceipt(recordingID) else { return }
        try requireActive()
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let document = document(for: draft)
        try await document.apply(.dictation(text))
        guard state == .active || state == .retiring else { throw ComposerDraftPersistence.Failure.retired }
        guard !draft.isDiscarded else { return }
        pendingReceipts[recordingID] = .init(draftID: draft.id, requiredRevision: draft.revision, receivedAt: .now)
    }

    func hasSavedReceipt(for recordingID: UUID) async throws -> Bool {
        try requireActive()
        let backing = try await open()
        try requireActive()
        let saved = try await backing.hasSavedReceipt(recordingID)
        try requireActive()
        return saved
    }

    func removeReceipts(receivedBefore cutoff: Date) async throws {
        try requireActive()
        guard await flush() else { throw DraftSaveError(message: errorMessage ?? "Draft receipts could not be saved.") }
        let backing = try await open()
        try requireActive()
        try await backing.removeReceipts(receivedBefore: cutoff)
    }

    private struct DraftSaveError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Clears the composer the moment a message is sent. Until the transcript
    /// durably holds the message, saves keep it in the draft, so a crash loses nothing.
    func beginSending(_ draft: ComposerDraft) -> OutgoingMessage? {
        guard acceptsChanges() else { return nil }
        let message = OutgoingMessage(draft: draft, content: document(for: draft).content, attachments: draft.attachments)
        outgoing[draft.id, default: []].append(message)
        applyContent(.init(runs: []), in: draft)
        draft.attachments = []
        draft.revision += 1
        pendingDocuments[draft.id] = draft
        return message
    }

    /// The transcript has durably accepted this exact submission. Later edits
    /// stay in its conversation, and New Chat now has its own empty slot.
    func submitted(_ message: OutgoingMessage, conversationID: UUID) {
        let draft = message.draft
        settle(message)
        guard acceptsChanges() else { return }
        if Destination.isNewChat(key: draft.destination) {
            draft.destination = Destination.conversation(conversationID).key
            draft.newChat = nil
        }
        remember(draft)
        draft.revision += 1
        pendingDocuments[draft.id] = draft
        requestFlush()
        restoreUnsent(in: draft)
    }

    /// The message never reached the transcript, so it returns to the composer
    /// ahead of anything typed since.
    func returnToComposer(_ message: OutgoingMessage) {
        unsent.insert(message.id)
        restoreUnsent(in: message.draft)
    }

    private func restoreUnsent(in draft: ComposerDraft) {
        guard let messages = outgoing[draft.id], messages.allSatisfy({ unsent.contains($0.id) }) else { return }
        let ids = Set(messages.map(\.id))
        guard !draft.isDiscarded else {
            unsent.subtract(ids)
            for message in messages { settle(message) }
            return
        }
        guard acceptsChanges() else { return }
        unsent.subtract(ids)
        document(for: draft).restore(Self.joined(messages, ahead: .init(runs: []))) { [weak self, weak draft] restored in
            guard let self, let draft else { return }
            guard restored else { unsent.formUnion(ids); return }
            for message in messages { settle(message) }
            draft.attachments = messages.flatMap(\.attachments) + draft.attachments
            changed(draft)
            restoreUnsent(in: draft)
        }
    }

    private func settle(_ message: OutgoingMessage) {
        outgoing[message.draft.id]?.removeAll { $0.id == message.id }
        if outgoing[message.draft.id]?.isEmpty == true { outgoing[message.draft.id] = nil }
    }

    private static func joined(_ messages: [OutgoingMessage], ahead current: ComposerDocumentContent) -> ComposerDocumentContent {
        guard !messages.isEmpty else { return current }
        var runs: [ComposerDocumentContent.Run] = []
        for part in messages.map(\.content) + [current] where !part.runs.isEmpty {
            if !runs.isEmpty { runs.append(.text("\n")) }
            runs += part.runs
        }
        return ComposerDocumentContent(runs: runs)
    }

    @discardableResult
    func applyTransfer(_ content: ComposerDocumentContent, attachments: [ComposerAttachment],
                       to draft: ComposerDraft, expectedRevision: Int) -> Bool {
        guard acceptsChanges() else { return false }
        let document = document(for: draft)
        guard draft.revision == expectedRevision, !document.isComposing else { return false }
        document.edit(.replaceAll(content))
        if draft.attachments != attachments {
            draft.attachments = attachments
            changed(draft)
        }
        pendingDocuments[draft.id] = draft
        return true
    }

    func bind(_ draft: ComposerDraft, to threadID: String) async {
        let destination = Destination.thread(threadID)
        guard draft.destination != destination.key else { return }
        let previous = draft.destination
        do {
            try requireActive()
            let backing = try await open()
            try requireActive()
            guard draft.destination == previous else { return }
            if let occupied = cachedDraft(for: destination), occupied !== draft {
                throw ComposerDraftPersistence.Failure.occupiedDestination
            }
            if let occupied = try await backing.load(destination: destination.key), occupied.snapshot.id != draft.id {
                throw ComposerDraftPersistence.Failure.occupiedDestination
            }
            try requireActive()
            guard draft.destination == previous else { return }
            if let occupied = cachedDraft(for: destination), occupied !== draft {
                throw ComposerDraftPersistence.Failure.occupiedDestination
            }
            draft.destination = destination.key
            if Destination.isNewChat(key: previous) { draft.newChat = nil }
            forget(previous)
            changed(draft)
            remember(draft)
            if await flush() { clearDestinationError(previous); clearDestinationError(destination.key) }
            if Destination.isNewChat(key: previous) { refreshUnsentDrafts() }
        } catch {
            recordDestinationError("Could not associate this draft with its conversation: \(error.localizedDescription)", key: draft.destination)
        }
    }

    /// Saves now. Returns whether the drafts are durably on disk, for callers
    /// that must not discard their own copy of a value until it is.
    @discardableResult
    func flush() async -> Bool {
        guard acceptsChanges() else { return false }
        return await flushPending()
    }

    private func flushPending() async -> Bool {
        saveTask?.cancel()
        saveTask = nil
        while !loading.isEmpty {
            let tasks = Array(loading.values)
            for task in tasks { await task.value }
        }
        if let writing { _ = await writing.value }
        guard !pendingDocuments.isEmpty || !pendingReceipts.isEmpty else { return state == .retiring || errorMessage == nil }
        return await startWriting().value
    }

    func requestFlush() {
        guard acceptsChanges() else { return }
        saveTask?.cancel()
        saveTask = nil
        guard !pendingDocuments.isEmpty || !pendingReceipts.isEmpty else { return }
        _ = startWriting()
    }

    @discardableResult
    func retire() async -> Bool {
        if state == .retired { return true }
        if let retirementTask { return await retirementTask.value }
        state = .retiring
        for document in documents.values.compactMap(\.value) { document.retire() }
        for discard in discards.values { discard.cancel() }
        discards.removeAll()
        unsentDraftsRefresh?.cancel()
        unsentDraftsRefresh = nil
        let delayedSave = saveTask
        delayedSave?.cancel()
        saveTask = nil
        let task = Task {
            await delayedSave?.value
            await withCheckedContinuation { continuation in
                if pendingDictations.isEmpty { continuation.resume() }
                else { dictationsDrained = continuation }
            }
            guard await flushPending() else { state = .recovery; return false }
            await persistence?.retire()
            persistence = nil
            opening = nil
            loading.removeAll()
            writing = nil
            cached.removeAll()
            references.removeAll()
            documents.removeAll()
            recency.removeAll()
            state = .retired
            return true
        }
        retirementTask = task
        let saved = await task.value
        retirementTask = nil
        return saved
    }

    private func requireActive() throws {
        guard state == .active else { throw ComposerDraftPersistence.Failure.retired }
    }

    private func acceptsChanges() -> Bool {
        do { try requireActive(); return true }
        catch { if errorMessage == nil { errorMessage = error.localizedDescription }; return false }
    }

    private func startWriting() -> Task<Bool, Never> {
        if let writing { return writing }
        let task = Task { await savePending() }
        writing = task
        return task
    }

    private func savePending() async -> Bool {
        var changesUnsentDrafts = false
        defer {
            writing = nil
            if changesUnsentDrafts { refreshUnsentDrafts() }
        }
        do {
            let backing = try await open()
            while !pendingDocuments.isEmpty || !pendingReceipts.isEmpty {
                let snapshots = pendingDocuments.values.prefix(ComposerDraftPersistence.batchLimit).map { draft in
                    let sending = outgoing[draft.id] ?? []
                    return ComposerDraftSnapshot(id: draft.id, destination: draft.destination, revision: draft.revision,
                        content: Self.joined(sending, ahead: document(for: draft).content),
                        attachments: sending.flatMap(\.attachments) + draft.attachments,
                        modifiedAt: draft.modifiedAt, newChat: draft.newChat)
                }
                if snapshots.contains(where: { Destination.threadID(for: $0.destination) == nil }) { changesUnsentDrafts = true }
                let included = Set(snapshots.map(\.id))
                let receipts = pendingReceipts.filter { included.contains($0.value.draftID) || pendingDocuments[$0.value.draftID] == nil }
                let saved = try await backing.save(snapshots, receipts: receipts)
                for receipt in saved {
                    guard let draft = pendingDocuments[receipt.id], draft.revision == receipt.revision,
                          let snapshot = snapshots.first(where: { $0.id == receipt.id }),
                          draft.destination == snapshot.destination else { continue }
                    draft.documentContent = snapshot.content
                    draft.text = receipt.text
                    pendingDocuments[receipt.id] = nil
                }
                for (id, date) in receipts where pendingReceipts[id] == date { pendingReceipts[id] = nil }
            }
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Draft changes could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    nonisolated static func importDrafts(from source: URL, into target: URL, conversationIDs: [UUID: UUID], hostID: UUID, accountID: UUID) throws {
        let original = try makeContext(directory: source)
        let destination = try makeContext(directory: target)
        let receipts = Set(try destination.fetch(FetchDescriptor<DraftImportReceipt>()).map(\.sourceDraftID))
        var savedByDestination = Dictionary(try destination.fetch(FetchDescriptor<ComposerDraft>()).map { ($0.destination, $0) },
                                            uniquingKeysWith: { first, _ in first })
        for draft in try original.fetch(FetchDescriptor<ComposerDraft>()) where !receipts.contains(draft.id) {
            var key = draft.destination
            if let slot = Destination.newChatID(for: key) {
                key = Destination.newChat(AccountRetirementMigration.draftSlot(hostID: hostID, accountID: accountID, slot: slot)).key
            }
            if key.hasPrefix("conversation:"), let id = UUID(uuidString: String(key.dropFirst("conversation:".count))),
               let replacement = conversationIDs[id] {
                key = Destination.conversation(replacement).key
            }
            let saved = savedByDestination[key]
            let copy = saved ?? ComposerDraft(destination: key)
            if saved == nil {
                copy.id = draft.id
                copy.modifiedAt = draft.modifiedAt
                copy.newChat = draft.newChat
                destination.insert(copy)
                savedByDestination[key] = copy
            }
            copy.newChat = copy.newChat ?? draft.newChat
            let sourceContent = persistedContent(draft)
            let targetContent = persistedContent(copy)
            let mergedContent: ComposerDocumentContent
            if sourceContent != targetContent {
                let separator: [ComposerDocumentContent.Run] = targetContent.runs.isEmpty || sourceContent.runs.isEmpty ? [] : [.text("\n\n")]
                let incoming = sourceContent.avoidingPasteIDs(Set(targetContent.pasted.map(\.id)))
                mergedContent = .init(runs: targetContent.runs + separator + incoming.runs)
            } else {
                mergedContent = targetContent
            }
            copy.documentContent = mergedContent
            copy.text = mergedContent.expandedText
            let attachmentIDs = Set(copy.attachments.map(\.id))
            copy.attachments = copy.attachments.filter { $0.text == nil }
                + draft.attachments.filter { $0.text == nil && !attachmentIDs.contains($0.id) }
            copy.revision += 1
            destination.insert(DraftImportReceipt(sourceDraftID: draft.id))
        }
        let recorded = Set(try destination.fetch(FetchDescriptor<DictationReceipt>()).map(\.recordingID))
        for receipt in try original.fetch(FetchDescriptor<DictationReceipt>()) where !recorded.contains(receipt.recordingID) {
            destination.insert(DictationReceipt(recordingID: receipt.recordingID, receivedAt: receipt.receivedAt))
        }
        try destination.save()
    }

    nonisolated static func persistedContent(_ draft: ComposerDraft) -> ComposerDocumentContent {
        draft.documentContent ?? ComposerDocumentContent(runs:
            (draft.text.isEmpty ? [] : [.text(draft.text)]) + draft.attachments.compactMap { attachment in
                guard let text = attachment.text else { return nil }
                return .paste(.init(id: attachment.id, text: text))
            })
    }

    private func changed(_ draft: ComposerDraft) {
        guard !draft.isDiscarded else { return }
        draft.modifiedAt = .now
        markDirty(draft)
    }

    private func markDirty(_ draft: ComposerDraft) {
        guard state == .active || state == .retiring, !draft.isDiscarded else { return }
        if draft.document != nil { pendingDocuments[draft.id] = draft }
        draft.revision += 1
        guard state == .active else { return }
        // Coalesce a burst without postponing saves indefinitely during typing.
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            _ = await self?.flush()
        }
    }

    private func open() async throws -> ComposerDraftPersistence {
        guard state != .retired else { throw ComposerDraftPersistence.Failure.retired }
        if let persistence { return persistence }
        let operation: (id: UUID, task: Task<ComposerDraftPersistence, Error>)
        if let opening { operation = opening }
        else {
            operation = (UUID(), Task { try await ComposerDraftPersistence.open(directory: directory) })
            opening = operation
        }
        do {
            let backing = try await operation.task.value
            guard state != .retired else { throw ComposerDraftPersistence.Failure.retired }
            if persistence == nil {
                persistence = backing
                refreshUnsentDrafts()
            }
            if opening?.id == operation.id { opening = nil }
            return persistence ?? backing
        } catch {
            if opening?.id == operation.id { opening = nil }
            throw error
        }
    }

    nonisolated static func makeContext(directory: URL) throws -> ModelContext {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let configuration = ModelConfiguration(url: directory.appending(path: "drafts.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: ComposerDraft.self, DictationReceipt.self, DraftImportReceipt.self, configurations: configuration)
        let context = ModelContext(container)
        // All writes, including chat switches and submission, have one owner.
        context.autosaveEnabled = false
        return context
    }

}
