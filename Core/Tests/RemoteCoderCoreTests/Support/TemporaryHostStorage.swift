import Foundation
@testable import RemoteCoderCore

struct TemporaryHostStorage: Sendable {
    let storage = HostStorage(root: FileManager.default.temporaryDirectory
        .appending(path: "RemoteCoderCoreTests-\(UUID().uuidString)"))

    func cleanUp() {
        try? FileManager.default.removeItem(at: storage.root)
    }
}
