import Foundation

struct HostFileReference: Hashable, Sendable {
    let hostID: UUID
    let path: String
    let lineAnchor: Int?

    init(hostID: UUID, path: String, lineAnchor: Int? = nil) throws {
        guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("\0"), lineAnchor.map({ $0 > 0 }) ?? true else {
            throw HostFileError.invalidPath
        }
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..":
                guard !components.isEmpty else { throw HostFileError.invalidPath }
                components.removeLast()
            default: components.append(component)
            }
        }
        self.hostID = hostID
        self.path = "/" + components.joined(separator: "/")
        self.lineAnchor = lineAnchor
    }

    static func resolve(url: URL, hostID: UUID, relativeTo directory: String?) throws -> HostFileReference? {
        guard let link = try HostFileLink(url: url) else { return nil }
        if link.path.hasPrefix("/") {
            return try HostFileReference(hostID: hostID, path: link.path, lineAnchor: link.lineAnchor)
        }
        guard link.isRelative, let directory, directory.hasPrefix("/") else {
            throw HostFileError.sourceDirectoryUnavailable
        }
        return try HostFileReference(hostID: hostID, path: directory + "/" + link.path, lineAnchor: link.lineAnchor)
    }
}

struct HostFileLink: Sendable {
    let path: String
    let lineAnchor: Int?
    let isRelative: Bool

    init?(url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw HostFileError.invalidPath
        }
        if let scheme = parts.scheme, scheme.lowercased() != "file" { return nil }
        guard parts.user == nil, parts.password == nil, parts.port == nil,
              parts.host == nil || parts.host == "" || parts.host?.lowercased() == "localhost",
              parts.query == nil,
              let decoded = parts.percentEncodedPath.removingPercentEncoding,
              !decoded.isEmpty else { throw HostFileError.invalidPath }
        if let fragment = parts.fragment, fragment.hasPrefix("L"),
           let number = Int(fragment.dropFirst()), number > 0 {
            lineAnchor = number
        } else {
            lineAnchor = nil
        }
        path = decoded
        isRelative = parts.scheme == nil
    }
}

struct HostFileProgress: Sendable {
    let bytesReceived: Int64
    let totalBytes: Int64?
}

struct HostFileLease: Identifiable, Sendable {
    let id: UUID
    let reference: HostFileReference
    let metadata: HostFileMetadata
    let url: URL
    let downloadedAt: Date
}

enum HostFileLimits {
    static let maximumFileBytes: Int64 = 1 << 30
    static let unheldCacheBytes: Int64 = 512 << 20
    static let workingSetBytes: Int64 = 2 << 30
    static let diskHeadroomBytes: Int64 = 64 << 20
    static let maximumTransfers = 2
    static let maximumCacheEntries = 256
}

enum HostFileError: Error, LocalizedError, Sendable, Equatable {
    case invalidPath
    case sourceDirectoryUnavailable
    case wrongHost
    case retired
    case unavailable
    case unauthorized
    case missing
    case accessDenied
    case notFile
    case tooLarge
    case busy
    case insufficientStorage
    case changed
    case invalidResponse
    case interrupted
    case storage
    case server(kind: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidPath: "This link does not identify a valid file on the source Mac."
        case .sourceDirectoryUnavailable: "The source folder is unknown. Open an absolute file link instead."
        case .wrongHost: "This file belongs to a different Mac. Open it from its original conversation."
        case .retired: "The source Mac's configuration changed. Open the file again from its conversation."
        case .unavailable: "The source Mac could not be reached. Check its connection and try again."
        case .unauthorized: "The gateway rejected access. Check this Mac's credentials in Settings."
        case .missing: "The file is no longer at this location on the Mac."
        case .accessDenied: "macOS denied access to this file. Check its permissions on the Mac."
        case .notFile: "This link points to a folder or another item that is not a regular file."
        case .tooLarge: "This file exceeds the 1 GiB download limit."
        case .busy: "Other files are still open or downloading. Close one and try again."
        case .insufficientStorage: "There is not enough free storage to download this file."
        case .changed: "The source file changed during download. Try again."
        case .invalidResponse: "The gateway returned incomplete or invalid file information. Try again."
        case .interrupted: "The file download was interrupted. Try again."
        case .storage: "The downloaded file could not be stored. Check available storage and try again."
        case .server(_, let message): message
        }
    }
}
