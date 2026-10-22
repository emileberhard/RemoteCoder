import Foundation

struct SharedItemsInbox: Sendable {
    struct Items: Codable, Equatable, Sendable {
        var files: [String] = []
        var text: [String] = []
    }

    struct Claim: Equatable, Sendable {
        let files: [URL]
        let text: [String]
    }

    struct Unavailable: LocalizedError {
        var errorDescription: String? { "The shared items are no longer available. Share them again." }
    }

    static let maximumItemCount = 32
    static let maximumBytes = 128 * 1024 * 1024
    static let unclaimedLifetime: TimeInterval = 3_600
    private static let manifestName = "manifest.json"

    let directory: URL

    init(appGroupContainer: URL) {
        directory = appGroupContainer.appending(path: "SharedItems", directoryHint: .isDirectory)
    }

    func begin(now: Date) throws -> Share {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        removeUnclaimed(createdBefore: now.addingTimeInterval(-Self.unclaimedLifetime))
        let share = Share(id: UUID(), directory: directory)
        try FileManager.default.createDirectory(at: share.folder, withIntermediateDirectories: false)
        return share
    }

    @concurrent func claim(_ id: UUID, into destination: URL) async throws -> Claim {
        let claimed = destination.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            try FileManager.default.moveItem(at: directory.appending(path: id.uuidString, directoryHint: .isDirectory), to: claimed)
        } catch CocoaError.fileNoSuchFile {
            throw Unavailable()
        }
        let manifest = claimed.appending(path: Self.manifestName, directoryHint: .notDirectory)
        let items = try JSONDecoder().decode(Items.self, from: Data(contentsOf: manifest))
        return Claim(files: items.files.map { claimed.appending(path: $0, directoryHint: .notDirectory) }, text: items.text)
    }

    private func removeUnclaimed(createdBefore cutoff: Date) {
        let shares = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for share in shares {
            guard let created = try? share.resourceValues(forKeys: [.creationDateKey]).creationDate,
                  created < cutoff else { continue }
            try? FileManager.default.removeItem(at: share)
        }
    }
}

extension SharedItemsInbox {
    struct Share: Sendable {
        let id: UUID
        let folder: URL

        fileprivate init(id: UUID, directory: URL) {
            self.id = id
            folder = directory.appending(path: id.uuidString, directoryHint: .isDirectory)
        }

        func move(_ file: URL, maximumBytes: Int) throws -> String {
            try validateSize(file, maximumBytes: maximumBytes)
            let (path, destination) = try slot(named: file.lastPathComponent)
            try FileManager.default.moveItem(at: file, to: destination)
            return path
        }

        func copy(_ file: URL, maximumBytes: Int) throws -> String {
            let (path, destination) = try slot(named: file.lastPathComponent)
            let hasScopedAccess = file.startAccessingSecurityScopedResource()
            defer { if hasScopedAccess { file.stopAccessingSecurityScopedResource() } }
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordinationError) { readable in
                do {
                    try validateSize(readable, maximumBytes: maximumBytes)
                    let input = try FileHandle(forReadingFrom: readable)
                    defer { try? input.close() }
                    guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    let output = try FileHandle(forWritingTo: destination)
                    defer { try? output.close() }
                    var remaining = maximumBytes
                    while let chunk = try input.read(upToCount: min(remaining + 1, 65_536)), !chunk.isEmpty {
                        guard chunk.count <= remaining else { throw CocoaError(.fileReadTooLarge) }
                        try output.write(contentsOf: chunk)
                        remaining -= chunk.count
                    }
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    copyError = error
                }
            }
            if let error = coordinationError ?? copyError { throw error }
            return path
        }

        func publish(_ items: Items) throws {
            try JSONEncoder().encode(items)
                .write(to: folder.appending(path: SharedItemsInbox.manifestName, directoryHint: .notDirectory), options: .atomic)
        }

        func discard() {
            try? FileManager.default.removeItem(at: folder)
        }

        private func validateSize(_ file: URL, maximumBytes: Int) throws {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize else { throw CocoaError(.fileReadUnsupportedScheme) }
            guard size <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        }

        private func slot(named name: String) throws -> (path: String, url: URL) {
            let slot = UUID().uuidString
            let slotFolder = folder.appending(path: slot, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: slotFolder, withIntermediateDirectories: false)
            return ("\(slot)/\(name)", slotFolder.appending(path: name, directoryHint: .notDirectory))
        }
    }
}
