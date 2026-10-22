import Foundation
import OSLog
import SwiftData

struct ComposerDraftSnapshot: Sendable {
    let id: UUID
    let destination: String
    let revision: Int
    let content: ComposerDocumentContent
    let attachments: [ComposerAttachment]
    let modifiedAt: Date?
    let newChat: NewChatSetup?

    var isBlankNewChat: Bool {
        ComposerDraftStore.Destination.isNewChat(key: destination) && attachments.isEmpty
            && content.expandedText.allSatisfy(\.isWhitespace)
    }
}

struct ComposerDraftSaveReceipt: Sendable {
    let id: UUID
    let revision: Int
    let text: String
}

struct ComposerDraftReceipt: Equatable, Sendable {
    let draftID: UUID
    let requiredRevision: Int
    let receivedAt: Date
}

@ModelActor
actor ComposerDraftPersistence {
    static let batchLimit = 16
    private var isRetired = false
    @concurrent
    static func open(directory: URL) async throws -> ComposerDraftPersistence {
        precondition(!Thread.isMainThread)
        return try ComposerDraftPersistence(directory: directory)
    }

    private init(directory: URL) throws {
        let context = try ComposerDraftStore.makeContext(directory: directory)
        do { try Self.adoptLegacyNewChatDrafts(in: context) } catch {
            context.rollback()
            Logger(subsystem: "RemoteCoder", category: "ComposerDrafts")
                .error("legacy new-chat drafts were not adopted: \(error.localizedDescription, privacy: .public)")
        }
        modelContainer = context.container
        modelExecutor = DefaultSerialModelExecutor(modelContext: context)
    }

    func load(destination: String) throws -> (snapshot: ComposerDraftSnapshot, text: String, needsSave: Bool)? {
        try requireActive()
        guard let draft = try existing(destination: destination) else { return nil }
        let value = snapshot(draft)
        return (value, value.content.expandedText, draft.documentContent == nil || draft.attachments.contains { $0.text != nil })
    }

    func save(_ drafts: [ComposerDraftSnapshot], receipts: [UUID: ComposerDraftReceipt]) throws -> [ComposerDraftSaveReceipt] {
        try requireActive()
        let started = ContinuousClock.now
        do {
            guard drafts.count <= Self.batchLimit else { throw Failure.batchTooLarge }
            var saved: [ComposerDraftSaveReceipt] = []
            var deleted: Set<UUID> = []
            for value in drafts {
                if value.isBlankNewChat {
                    if let existing = try existing(id: value.id) { modelContext.delete(existing) }
                    deleted.insert(value.id)
                    saved.append(.init(id: value.id, revision: value.revision, text: ""))
                    continue
                }
                // Never let SwiftData's uniqueness upsert overwrite another draft.
                if let occupied = try existing(destination: value.destination), occupied.id != value.id {
                    throw Failure.occupiedDestination
                }
                let draft: ComposerDraft
                if let existing = try existing(id: value.id) { draft = existing }
                else {
                    draft = ComposerDraft(destination: value.destination)
                    draft.id = value.id
                    modelContext.insert(draft)
                }
                let text = value.content.expandedText
                draft.destination = value.destination
                draft.revision = value.revision
                draft.documentContent = value.content
                draft.text = text
                draft.attachments = value.attachments
                draft.modifiedAt = value.modifiedAt
                draft.newChat = value.newChat
                saved.append(.init(id: value.id, revision: value.revision, text: text))
            }
            for (id, receipt) in receipts where try modelContext.fetchCount(receiptDescriptor(id)) == 0 {
                if !deleted.contains(receipt.draftID) {
                    guard let owner = try existing(id: receipt.draftID),
                          owner.revision >= receipt.requiredRevision else { throw Failure.unsavedReceipt }
                }
                modelContext.insert(DictationReceipt(recordingID: id, receivedAt: receipt.receivedAt))
            }
            if modelContext.hasChanges {
                try modelContext.save()
                // SwiftData owns physical/WAL bytes; do not report a fabricated size.
                PersistenceMetrics.shared.wrote(.drafts, bytes: nil, elapsed: started.duration(to: .now))
            } else { PersistenceMetrics.shared.skipped(.drafts) }
            return saved
        } catch {
            modelContext.rollback()
            PersistenceMetrics.shared.failed(.drafts)
            throw error
        }
    }

    func hasSavedReceipt(_ id: UUID) throws -> Bool {
        try requireActive()
        var descriptor = receiptDescriptor(id)
        descriptor.includePendingChanges = false
        return try modelContext.fetchCount(descriptor) > 0
    }

    func removeReceipts(receivedBefore cutoff: Date) throws {
        try requireActive()
        let expired = try modelContext.fetch(FetchDescriptor<DictationReceipt>(predicate: #Predicate { $0.receivedAt < cutoff }))
        guard !expired.isEmpty else { return }
        do {
            expired.forEach(modelContext.delete)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func unsentDrafts() throws -> [UnsentDraftSummary] {
        try requireActive()
        let prefix = ComposerDraftStore.Destination.newChatPrefix
        let drafts = try modelContext.fetch(FetchDescriptor<ComposerDraft>(predicate: #Predicate { $0.destination.starts(with: prefix) }))
        return drafts.compactMap { draft in
            guard let id = ComposerDraftStore.Destination.newChatID(for: draft.destination),
                  let title = UnsentDraftSummary.title(text: draft.text, attachmentCount: draft.attachments.count) else { return nil }
            return UnsentDraftSummary(id: id, title: title, setup: draft.newChat, modifiedAt: draft.modifiedAt)
        }
        .sorted(by: UnsentDraftSummary.newestFirst)
    }

    func delete(destination: String) throws {
        try requireActive()
        guard let draft = try existing(destination: destination) else { return }
        do {
            modelContext.delete(draft)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private static func adoptLegacyNewChatDrafts(in context: ModelContext) throws {
        let legacyKey = "new-chat"
        let prefix = ComposerDraftStore.Destination.newChatPrefix
        let drafts = try context.fetch(FetchDescriptor<ComposerDraft>(
            predicate: #Predicate { $0.destination == legacyKey || $0.destination.starts(with: prefix) }))
        for draft in drafts {
            let isBlank = !draft.attachments.contains { $0.text == nil }
                && ComposerDraftStore.persistedContent(draft).expandedText.allSatisfy(\.isWhitespace)
            if isBlank { context.delete(draft) }
            else if draft.destination == legacyKey { draft.destination = ComposerDraftStore.Destination.newChat(draft.id).key }
        }
        if context.hasChanges { try context.save() }
    }

    private func snapshot(_ draft: ComposerDraft) -> ComposerDraftSnapshot {
        .init(id: draft.id, destination: draft.destination, revision: draft.revision,
            content: ComposerDraftStore.persistedContent(draft), attachments: draft.attachments.filter { $0.text == nil },
            modifiedAt: draft.modifiedAt, newChat: draft.newChat)
    }

    private func existing(id: UUID) throws -> ComposerDraft? {
        var descriptor = FetchDescriptor<ComposerDraft>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func existing(destination: String) throws -> ComposerDraft? {
        var descriptor = FetchDescriptor<ComposerDraft>(predicate: #Predicate { $0.destination == destination })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func receiptDescriptor(_ id: UUID) -> FetchDescriptor<DictationReceipt> {
        FetchDescriptor<DictationReceipt>(predicate: #Predicate { $0.recordingID == id })
    }

    func retire() {
        isRetired = true
    }

    private func requireActive() throws {
        guard !isRetired else { throw Failure.retired }
    }

    enum Failure: LocalizedError {
        case occupiedDestination
        case batchTooLarge
        case unsavedReceipt
        case retired
        var errorDescription: String? {
            switch self {
            case .occupiedDestination: "This conversation already has a draft. The earlier draft is preserved."
            case .batchTooLarge: "Too many drafts were submitted in one save."
            case .unsavedReceipt: "This dictation's draft has not been saved yet."
            case .retired: "This draft storage has retired."
            }
        }
    }
}
