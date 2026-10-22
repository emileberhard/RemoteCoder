import Foundation

final class CondensedPathCache {
    private struct Key: Hashable {
        let path: String
        let remoteHomePath: String?
    }

    private var paths: [Key: String] = [:]

    func condensedPath(_ path: String, remoteHomePath: String?) -> String {
        let key = Key(path: path, remoteHomePath: remoteHomePath)
        if let cached = paths[key] { return cached }
        let condensed = WorkingDirectoryPathFormatter.condensedPath(path, remoteHomePath: remoteHomePath)
        paths[key] = condensed
        return condensed
    }
}
