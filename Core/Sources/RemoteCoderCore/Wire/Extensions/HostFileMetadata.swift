import Foundation

struct HostFileMetadata: Codable, Equatable, Sendable {
    let path: String
    let name: String
    let bytes: Int64
    let modifiedAt: Double
    let revision: String
}
