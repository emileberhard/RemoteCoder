import Foundation

struct ProjectIdentity: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case remote
        case repository
        case directory
    }

    let cwd: String
    let kind: Kind
    let key: String
    let name: String
    let root: String
}
