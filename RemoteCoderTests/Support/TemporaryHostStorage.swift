import Foundation
@testable import RemoteCoder

struct TemporaryHostStorage {
    let storage: HostStorage
    let defaults: UserDefaults
    private let suiteName: String

    init() {
        let id = UUID().uuidString
        suiteName = "RemoteCoderTests.\(id)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create isolated test defaults")
        }
        self.defaults = defaults
        storage = HostStorage(root: FileManager.default.temporaryDirectory.appending(path: "RemoteCoderTests-\(id)"))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: storage.root)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
