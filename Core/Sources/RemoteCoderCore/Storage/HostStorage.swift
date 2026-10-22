import Foundation

enum StorageScope: Sendable {
    case device
    case host(UUID)
    case account(host: UUID, account: UUID)

    static func target(hostID: UUID?) -> StorageScope {
        hostID.map(StorageScope.host) ?? .device
    }
}

struct HostStorage: Sendable {
    static let live = HostStorage(root: AppStorageScope.current.applicationSupport.appending(path: "RemoteCoder"))

    let root: URL

    func directory(for scope: StorageScope) -> URL {
        switch scope {
        case .device:
            root
        case .host(let host):
            root.appending(path: "hosts/\(host.uuidString)", directoryHint: .isDirectory)
        case .account(let host, let account):
            root.appending(path: "hosts/\(host.uuidString)/accounts/\(account.uuidString)", directoryHint: .isDirectory)
        }
    }
}
