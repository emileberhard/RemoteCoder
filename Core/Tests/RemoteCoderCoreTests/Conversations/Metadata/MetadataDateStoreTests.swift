import Foundation
import Testing
@testable import RemoteCoderCore

struct MetadataDateStoreTests {
    @Test func sameSecondSelectionSurvivesSaveReloadAndRestoration() async throws {
        let fixture = Fixture()
        defer { fixture.temporary.cleanUp() }
        let thread = try ThreadFixture.basic("claude_1", updatedAt: 1_791_000_000,
            fields: ["model": "opus", "reasoningEffort": "low"])
        let saved = ConversationMetadata(sessionID: thread.id, modelID: "sonnet",
            reasoningSelectionID: "effort-high", fastModeEnabled: false, source: .selection,
            updatedAt: Date(timeIntervalSince1970: Double(thread.updatedAt) + 0.75), serverRevision: 2)
        try await fixture.store.save(.init(acknowledged: [thread.id: saved]))
        let restored = try #require(try await fixture.store.load().acknowledged[thread.id])
        #expect(restored.updatedAt == saved.updatedAt)
        var selection = ConversationSettingsSelection(model: nil, reasoning: .automatic, fastMode: .selection(nil))
        #expect(selection.restore(from: thread, saved: restored,
            resolveOption: { id, _, _ in ClaudeModelCatalog.model(for: id) }) == .savedSelection)
        #expect(selection.model == ClaudeModelCatalog.model(for: "sonnet"))
        #expect(selection.reasoning == .effort(.high))
    }

    @Test(arguments: [800_000_000.125, 800_000_000.125.nextUp, -0.000_000_001])
    func acknowledgedAndPendingDatesRoundTripExactly(timestamp: Double) async throws {
        let fixture = Fixture()
        defer { fixture.temporary.cleanUp() }
        let date = Date(timeIntervalSinceReferenceDate: timestamp)
        let record = ConversationMetadata(sessionID: "chat", modelID: "opus",
            reasoningSelectionID: "automatic", source: .selection, updatedAt: date, serverRevision: 1)
        let pending = SessionMetadataPending(mutation: .init(selection: record.selection,
            expectedRevision: 1, mutationID: "pending"), createdAt: date)
        let state = SessionMetadataLocalState(acknowledged: ["chat": record], pending: ["chat": pending], invalidated: ["chat"])
        try await fixture.store.save(state)
        #expect(try await fixture.store.load() == state)
    }

    @Test(arguments: [false, true])
    func wholeSecondLegacyDatesRemainReadable(array: Bool) async throws {
        let fixture = Fixture()
        defer { fixture.temporary.cleanUp() }
        let record = ConversationMetadata(sessionID: "chat", modelID: "opus",
            reasoningSelectionID: "automatic", source: .selection,
            updatedAt: Date(timeIntervalSince1970: 1_791_000_000), serverRevision: 1)
        let pending = SessionMetadataPending(mutation: .init(selection: record.selection,
            expectedRevision: 1, mutationID: "pending"), createdAt: record.updatedAt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacy = SessionMetadataLocalState(version: 2, acknowledged: ["chat": record], pending: ["chat": pending], invalidated: ["chat"])
        let data = try array ? encoder.encode([record]) : encoder.encode(legacy)
        try fixture.seed(data)
        let loaded = try await fixture.store.load()
        #expect(loaded.version == 3)
        if array {
            #expect(loaded.legacy == ["chat": record])
        } else {
            #expect(loaded.acknowledged == legacy.acknowledged)
            #expect(loaded.pending == legacy.pending)
            #expect(loaded.invalidated == legacy.invalidated)
        }
        #expect(try Data(contentsOf: fixture.file) == data)
        try await fixture.store.save(loaded)
        #expect(try await fixture.store.load() == loaded)
    }

    @Test func unsupportedSchemaIsRejectedBeforeItsDatesAndIsNotReplaced() async throws {
        let fixture = Fixture()
        defer { fixture.temporary.cleanUp() }
        let data = Data(#"{"version":4,"acknowledged":{"chat":{"updatedAt":"unreadable"}}}"#.utf8)
        try fixture.seed(data)
        await #expect(throws: ConversationMetadataStore.Failure.unsupportedVersion) { try await fixture.store.load() }
        #expect(try Data(contentsOf: fixture.file) == data)
    }

    private struct Fixture {
        let hostID = UUID()
        let temporary = TemporaryHostStorage()
        let store: ConversationMetadataStore
        var directory: URL { temporary.storage.directory(for: .host(hostID)) }
        var file: URL { directory.appending(path: "codex-session-metadata.json") }
        init() { store = ConversationMetadataStore(hostID: hostID, storage: temporary.storage) }
        func seed(_ data: Data) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file)
        }
    }
}
