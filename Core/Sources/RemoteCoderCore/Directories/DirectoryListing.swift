import Foundation

/// One remote directory's subdirectories: hidden entries filtered, sorted for
/// display. `path` is always the expanded, absolute path that was listed.
struct DirectoryListing: Equatable, Sendable {
    let path: String
    let childNames: [String]

    init(path: String, childNames: [String]) {
        self.path = path
        self.childNames = childNames
    }

    init(path: String, response: CodexAppServerV2.FsReadDirectoryResponse) {
        self.path = path
        childNames = response.entries
            .filter { $0.isDirectory && !$0.fileName.hasPrefix(".") }
            .map(\.fileName)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var childItems: [DirectoryItem] {
        childNames.map { DirectoryItem(path: "\(path)/\($0)") }
    }
}
