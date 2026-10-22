import Foundation
import Testing

nonisolated struct FileIdentity: Equatable {
    let inode: UInt64
    let modified: Date
    let bytes: Data

    init(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        inode = try #require(attributes[.systemFileNumber] as? NSNumber).uint64Value
        modified = try #require(attributes[.modificationDate] as? Date)
        bytes = try Data(contentsOf: url)
    }
}
