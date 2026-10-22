import Foundation

struct HostHTMLDocument: Sendable {
    static let scheme = "host-file-preview"

    let url: URL
    let directory: String
    private let hostID: UUID

    static func admits(_ lease: HostFileLease) -> Bool {
        ["html", "htm", "xhtml"].contains((lease.metadata.name as NSString).pathExtension.lowercased())
    }

    init(lease: HostFileLease) throws {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = lease.id.uuidString.lowercased()
        components.path = lease.reference.path
        guard let url = components.url else { throw HostFileError.invalidPath }
        self.url = url
        hostID = lease.reference.hostID
        directory = (lease.reference.path as NSString).deletingLastPathComponent
    }

    func contains(_ destination: URL) -> Bool {
        guard let components = URLComponents(url: destination, resolvingAgainstBaseURL: true),
              let original = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme == original.scheme && components.host == original.host
            && components.percentEncodedPath == original.percentEncodedPath
            && components.user == nil && components.password == nil && components.port == nil
    }

    func remoteFileURL(for destination: URL) -> URL? {
        guard var components = URLComponents(url: destination, resolvingAgainstBaseURL: true),
              components.scheme == Self.scheme, components.host == url.host,
              components.user == nil, components.password == nil, components.port == nil else { return nil }
        components.scheme = "file"
        components.host = nil
        components.query = nil
        guard let decoded = components.percentEncodedPath.removingPercentEncoding,
              let reference = try? HostFileReference(hostID: hostID, path: decoded),
              reference.path.hasPrefix(directory == "/" ? "/" : directory + "/") else { return nil }
        components.path = reference.path
        return components.url
    }

    func previewURL(for fileURL: URL) -> URL? {
        guard fileURL.isFileURL,
              var components = URLComponents(url: fileURL, resolvingAgainstBaseURL: true),
              components.host == nil || components.host == "" || components.host?.lowercased() == "localhost",
              components.user == nil, components.password == nil, components.port == nil else { return nil }
        components.scheme = Self.scheme
        components.host = url.host
        guard let candidate = components.url, remoteFileURL(for: candidate) != nil else { return nil }
        return candidate
    }
}
