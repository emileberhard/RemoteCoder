import Foundation

struct DirectoryFavorites: Codable, Equatable, Sendable {
    let revision: UInt64
    let paths: [String]
}

enum DirectoryFavoriteChange: Codable, Equatable, Sendable {
    case add(String)
    case remove(String)

    private enum CodingKeys: String, CodingKey { case op, path }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decode(String.self, forKey: .path)
        switch try container.decode(String.self, forKey: .op) {
        case "add": self = .add(path)
        case "remove": self = .remove(path)
        case let op:
            throw DecodingError.dataCorruptedError(forKey: .op, in: container, debugDescription: "unknown favorite change \(op)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .add(let path):
            try container.encode("add", forKey: .op)
            try container.encode(path, forKey: .path)
        case .remove(let path):
            try container.encode("remove", forKey: .op)
            try container.encode(path, forKey: .path)
        }
    }

    var path: String {
        switch self {
        case .add(let path), .remove(let path): path
        }
    }

    func applied(to paths: [String]) -> [String] {
        switch self {
        case .add(let path): paths.contains(path) ? paths : [path] + paths
        case .remove(let path): paths.filter { $0 != path }
        }
    }
}

struct DirectoryFavoritesReplica: Codable, Equatable, Sendable {
    static let changeLimit = 100
    private static let pathByteLimit = 1024

    private(set) var acknowledged: DirectoryFavorites?
    private(set) var pending: [DirectoryFavoriteChange] = []

    init() {}

    init(legacyPaths: [String]) {
        var seen: Set<String> = []
        let paths = legacyPaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { Self.accepts($0) && seen.insert($0).inserted }
        pending = paths.prefix(Self.changeLimit).reversed().map(DirectoryFavoriteChange.add)
    }

    private static func accepts(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= pathByteLimit
            && !path.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    var paths: [String] {
        pending.reduce(acknowledged?.paths ?? []) { $1.applied(to: $0) }
    }

    mutating func record(_ change: DirectoryFavoriteChange) -> Bool {
        guard pending.count < Self.changeLimit, Self.accepts(change.path) else { return false }
        pending.append(change)
        return true
    }

    mutating func replace(with read: DirectoryFavorites) {
        acknowledged = read
    }

    mutating func receive(_ favorites: DirectoryFavorites) {
        guard acknowledged.map({ $0.revision <= favorites.revision }) ?? true else { return }
        acknowledged = favorites
    }

    mutating func acknowledge(_ count: Int, current: DirectoryFavorites) {
        pending.removeFirst(count)
        receive(current)
    }

    mutating func reject(_ count: Int) {
        pending.removeFirst(count)
    }
}
