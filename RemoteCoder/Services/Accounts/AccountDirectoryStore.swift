import Foundation

actor AccountDirectoryStore {
    private let storage: HostStorage

    init(storage: HostStorage = .live) {
        self.storage = storage
    }

    func load(hostID: UUID) -> AccountDirectoryResponse? {
        guard let data = try? Data(contentsOf: path(hostID)), data.count <= 2 * 1_024 * 1_024,
              var response = try? JSONDecoder().decode(AccountDirectoryResponse.self, from: data),
              response.schemaVersion == 2 else { return nil }
        for index in response.accounts.indices {
            response.accounts[index].stale = true
            if response.accounts[index].state == .ready { response.accounts[index].state = .unavailable }
        }
        return response
    }
    func save(_ response: AccountDirectoryResponse, hostID: UUID) throws {
        let url = path(hostID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(response).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func path(_ hostID: UUID) -> URL {
        storage.directory(for: .host(hostID)).appending(path: "account-directory-v1.json")
    }
}
