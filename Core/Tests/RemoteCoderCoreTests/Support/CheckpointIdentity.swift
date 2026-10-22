import Foundation

nonisolated struct CheckpointIdentity: Equatable {
    let database: FileIdentity
    let wal: FileIdentity?

    init(_ url: URL) throws {
        database = try FileIdentity(url)
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        wal = FileManager.default.fileExists(atPath: walURL.path) ? try FileIdentity(walURL) : nil
    }
}
