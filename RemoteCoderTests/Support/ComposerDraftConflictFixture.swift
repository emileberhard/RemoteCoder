import Foundation
@testable import RemoteCoder

func writeConflictingDraft(id: UUID, destination: String, directory: URL) async throws {
    let persistence = try await ComposerDraftPersistence.open(directory: directory)
    defer { await persistence.retire() }
    if let saved = try await persistence.load(destination: destination), saved.snapshot.id != id {
        let snapshot = saved.snapshot
        _ = try await persistence.save([.init(id: snapshot.id, destination: "thread:displaced-\(snapshot.id.uuidString)",
            revision: snapshot.revision, content: snapshot.content, attachments: snapshot.attachments,
            modifiedAt: snapshot.modifiedAt, newChat: snapshot.newChat)], receipts: [:])
    }
    _ = try await persistence.save([.init(id: id, destination: destination, revision: 0,
        content: .init(runs: [.text("Another owner's draft")]), attachments: [], modifiedAt: nil, newChat: nil)], receipts: [:])
}
