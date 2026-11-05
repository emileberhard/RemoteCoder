import Foundation
#if canImport(RemoteCoderCore)
@testable import RemoteCoderCore
#else
@testable import RemoteCoder
#endif

struct TemporaryHostStorage: Sendable {
    let storage = HostStorage(root: FileManager.default.temporaryDirectory
        .appending(path: "RemoteCoderCoreTests-\(UUID().uuidString)"))

    var defaults: UserDefaults {
        guard let defaults = UserDefaults(suiteName: storage.root.lastPathComponent) else {
            preconditionFailure("Could not create isolated test defaults")
        }
        return defaults
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: storage.root)
        defaults.removePersistentDomain(forName: storage.root.lastPathComponent)
    }
}
