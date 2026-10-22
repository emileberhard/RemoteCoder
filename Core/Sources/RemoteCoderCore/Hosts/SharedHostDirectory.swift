import Foundation

actor SharedHostDirectory {
    private let storage: any GatewayCredentialStorage

    init(storage: any GatewayCredentialStorage) {
        self.storage = storage
    }

    func read() throws -> HostDirectory? {
        try storage.read().map { try JSONDecoder().decode(HostDirectory.self, from: $0) }
    }

    func replace(_ expected: HostDirectory?, with directory: HostDirectory) throws -> Bool {
        guard try read() == expected else { return false }
        try storage.write(JSONEncoder().encode(directory))
        return true
    }
}
