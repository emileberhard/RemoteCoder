import Foundation

enum CameraCaptureBatch {
    static let maximumPhotos = 24
    struct Invalid: LocalizedError {
        var errorDescription: String? { "The confirmed camera photos are invalid." }
    }

    private static let manifest = "ConfirmedPhotos.json"

    static func confirm(_ files: [URL], in directory: URL) throws {
        let root = directory.standardizedFileURL.path + "/"
        let paths = try files.map { file in
            let path = file.standardizedFileURL.path
            guard path.hasPrefix(root) else { throw Invalid() }
            let relative = String(path.dropFirst(root.count))
            try validate(relative)
            return relative
        }
        guard !paths.isEmpty, paths.count <= maximumPhotos, Set(paths).count == paths.count else { throw Invalid() }
        try JSONEncoder().encode(paths).write(to: directory.appending(path: manifest), options: .atomic)
    }

    static func confirmedFiles(in directory: URL) throws -> [URL]? {
        let data: Data
        do { data = try Data(contentsOf: directory.appending(path: manifest)) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        let paths = try JSONDecoder().decode([String].self, from: data)
        guard !paths.isEmpty, paths.count <= maximumPhotos, Set(paths).count == paths.count else { throw Invalid() }
        return try paths.map { path in
            try validate(path)
            return directory.appending(path: path)
        }
    }

    static func unconfirm(in directory: URL) throws {
        do { try FileManager.default.removeItem(at: directory.appending(path: manifest)) }
        catch CocoaError.fileNoSuchFile {}
    }

    @concurrent static func discard(in directory: URL) async throws {
        do { try FileManager.default.removeItem(at: directory) }
        catch CocoaError.fileNoSuchFile {}
    }

    @concurrent static func discardPhoto(_ file: URL) async throws {
        try await discard(in: file.deletingLastPathComponent())
    }

    @concurrent static func importFiles(_ files: [URL], from directory: URL,
        admit: @escaping @MainActor @Sendable ([URL]) throws -> Void) async throws {
        var moved: [(original: URL, destination: URL)] = []
        do {
            for file in files {
                try Task.checkCancellation()
                let folder = URL.temporaryDirectory.appending(path: "CameraImports/\(UUID())", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = folder.appending(path: file.lastPathComponent)
                do { try FileManager.default.moveItem(at: file, to: destination) }
                catch {
                    try FileManager.default.removeItem(at: destination.deletingLastPathComponent())
                    throw error
                }
                moved.append((file, destination))
            }
            try await admit(moved.map(\.destination))
        } catch {
            for file in moved.reversed() {
                try FileManager.default.moveItem(at: file.destination, to: file.original)
                try FileManager.default.removeItem(at: file.destination.deletingLastPathComponent())
            }
            throw error
        }
        try await discard(in: directory)
    }

    private static func validate(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, UUID(uuidString: String(components[0])) != nil,
              ["Photo.heic", "Photo.jpg"].contains(String(components[1])) else { throw Invalid() }
    }
}
