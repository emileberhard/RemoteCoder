import Foundation

extension HostFileMetadata {
    func validate(path requestedPath: String, maximumBytes: Int64) throws {
        guard path == requestedPath, !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\0"),
              name == path.split(separator: "/").last.map(String.init),
              bytes >= 0, modifiedAt.isFinite, !revision.isEmpty, revision.utf8.count <= 1024 else {
            throw HostFileError.invalidResponse
        }
        guard bytes <= maximumBytes else { throw HostFileError.tooLarge }
    }
}
