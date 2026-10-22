import Foundation
import Testing

@testable import RemoteCoderCore

struct UndecodableStoreRecoveryTests {
    @Test func failedMovePreservesAllFourExistingCopies() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appending(path: UUID().uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let source = directory.appending(path: "store.json")
        let copies = (0...3).map { sequence in
            directory.appending(path: sequence == 0 ? "store.undecodable.json" : "store.undecodable.\(sequence).json")
        }
        let bytes = (0...3).map { Data("corruption \($0)".utf8) }
        for (copy, data) in zip(copies, bytes) { try data.write(to: copy) }

        #expect(throws: CocoaError.self) {
            try UndecodableStoreRecovery.setAside(source)
        }

        let retainedNames = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
        #expect(Set(retainedNames) == Set(copies.map(\.lastPathComponent)))
        for (copy, data) in zip(copies, bytes) {
            #expect(try Data(contentsOf: copy) == data)
        }
    }

    @Test(arguments: ["voice-history.json", "conversation-marks.v2.json"])
    func repeatedCorruptionPreservesThreeNewestCopies(_ fileName: String) async throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appending(path: UUID().uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let source = directory.appending(path: fileName)
        let prefix = source.deletingPathExtension().lastPathComponent + ".undecodable"
        let unrelated = directory.appending(path: "unrelated.undecodable.json")
        let unrelatedBytes = Data("unrelated recovery evidence".utf8)
        try unrelatedBytes.write(to: unrelated)
        let corruptions = (1...5).map { Data("{\"corruption\":\($0),".utf8) }

        for index in corruptions.indices {
            try corruptions[index].write(to: source)
            if fileName == "voice-history.json" {
                #expect(await RealtimeVoiceHistoryStore(fileURL: source).entries(for: "thread").isEmpty)
            } else {
                guard case .missing = await ConversationMarksStore(directory: directory).load() else {
                    Issue.record("expected marks to recover after preservation")
                    return
                }
            }

            #expect(!manager.fileExists(atPath: source.path))
            let copies = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(prefix) }
            let retained = try copies.map { try Data(contentsOf: $0) }
            let expected = Array(corruptions.prefix(index + 1).suffix(3))
            #expect(retained.count == expected.count)
            #expect(Set(retained) == Set(expected))
            #expect(try Data(contentsOf: unrelated) == unrelatedBytes)
        }

        let blockedDirectory = directory.appending(path: "blocked")
        try manager.createDirectory(at: blockedDirectory, withIntermediateDirectories: true)
        let blockedSource = blockedDirectory.appending(path: fileName)
        let blockedArchive = blockedSource.deletingPathExtension().appendingPathExtension("undecodable.json")
        try manager.createDirectory(at: blockedArchive, withIntermediateDirectories: true)
        let existingEvidence = blockedArchive.appending(path: "evidence")
        try unrelatedBytes.write(to: existingEvidence)
        try corruptions[0].write(to: blockedSource)

        if fileName == "voice-history.json" {
            let store = RealtimeVoiceHistoryStore(fileURL: blockedSource)
            await store.append(role: .user, text: "Must not replace corruption", date: Date(timeIntervalSince1970: 1), threadID: "thread")
            await store.flush()
        } else {
            guard case .unavailable = await ConversationMarksStore(directory: blockedDirectory).load() else {
                Issue.record("failed preservation must leave marks unavailable")
                return
            }
        }
        #expect(try Data(contentsOf: blockedSource) == corruptions[0])
        #expect(try Data(contentsOf: existingEvidence) == unrelatedBytes)
    }
}
