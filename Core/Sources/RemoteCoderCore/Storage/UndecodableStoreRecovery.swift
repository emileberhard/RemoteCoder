import Foundation
import OSLog
import Synchronization

nonisolated enum UndecodableStoreRecovery {
    private static let maximumCopies = 3
    private static let lock = Mutex(())
    private static let logger = AppLogger(category: "UndecodableStoreRecovery")

    static func setAside(_ fileURL: URL) throws {
        try lock.withLock { _ in
            let manager = FileManager.default
            let directory = fileURL.deletingLastPathComponent()
            let baseName = fileURL.deletingPathExtension().lastPathComponent + ".undecodable"
            let copies = try manager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ).compactMap { url -> (url: URL, sequence: UInt64)? in
                guard let sequence = archiveSequence(url.lastPathComponent, baseName: baseName) else { return nil }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
                }
                return (url, sequence)
            }.sorted { $0.sequence < $1.sequence }

            let sequence: UInt64
            if let latest = copies.last {
                let next = latest.sequence.addingReportingOverflow(1)
                guard !next.overflow else {
                    throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: fileURL.path])
                }
                sequence = next.partialValue
            } else {
                sequence = 0
            }
            let name = sequence == 0 ? "\(baseName).json" : "\(baseName).\(sequence).json"
            let destination = directory.appending(path: name)
            try manager.moveItem(at: fileURL, to: destination)
            logger.notice("Preserved undecodable store at \(destination.path)")

            for copy in copies.prefix(max(0, copies.count + 1 - maximumCopies)) {
                try evict(copy.url)
            }
        }
    }

    private static func archiveSequence(_ name: String, baseName: String) -> UInt64? {
        if name == "\(baseName).json" { return 0 }
        let prefix = baseName + "."
        guard name.hasPrefix(prefix), name.hasSuffix(".json") else { return nil }
        let suffix = name.dropFirst(prefix.count).dropLast(".json".count)
        guard let sequence = UInt64(suffix), sequence > 0, String(sequence) == suffix else { return nil }
        return sequence
    }

    private static func evict(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
        logger.notice("Evicted oldest undecodable store copy at \(url.path); retaining at most \(maximumCopies) copies per store")
    }
}
