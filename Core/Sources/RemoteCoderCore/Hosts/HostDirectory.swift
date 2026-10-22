import Foundation

struct HostDirectory: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let id: UUID
        var name: String
        var hostname: String
        var port: Int
        var transport: GatewayTransport
        var enrollmentToken: String?
        var modifiedAt: Date

        init(_ host: GatewayHostConfiguration, enrollmentToken: String?, modifiedAt: Date) {
            id = host.id
            name = host.name
            hostname = host.hostname
            port = host.port
            transport = host.transport
            self.enrollmentToken = enrollmentToken
            self.modifiedAt = modifiedAt
        }

        func configuration(updating current: GatewayHostConfiguration?) -> GatewayHostConfiguration {
            var host = GatewayHostConfiguration(id: id, name: name, hostname: hostname, port: port,
                authToken: enrollmentToken ?? "", transport: transport)
            guard let current, current.hasSameEndpoint(as: host) else { return host }
            if current.usesInstallationCredential || enrollmentToken == nil { host.authToken = current.authToken }
            if current.hasSameConnection(as: host) { host.incomingCallHostID = current.incomingCallHostID }
            return host
        }

        func hasSameEndpoint(as host: GatewayHostConfiguration) -> Bool {
            configuration(updating: nil).hasSameEndpoint(as: host)
        }
    }

    struct Deletion: Codable, Equatable, Sendable {
        let id: UUID
        let deletedAt: Date
    }

    struct UnsupportedVersion: LocalizedError {
        let version: Int
        var errorDescription: String? {
            "Another device synced hosts with a newer RemoteCoder (format \(version)). Update this device to keep syncing."
        }
    }

    static let deletionLimit = 256
    private static let version = 1

    private(set) var entries: [Entry] = []
    private(set) var deletions: [Deletion] = []

    init() {}

    private enum CodingKeys: String, CodingKey { case version, entries, deletions }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        guard version == Self.version else { throw UnsupportedVersion(version: version) }
        entries = try values.decode([Entry].self, forKey: .entries)
        deletions = try values.decode([Deletion].self, forKey: .deletions)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.version, forKey: .version)
        try values.encode(entries, forKey: .entries)
        try values.encode(deletions, forKey: .deletions)
    }

    mutating func adopt(_ hosts: [GatewayHostConfiguration]) {
        for host in hosts where !entries.contains(where: { $0.id == host.id }) && !deletions.contains(where: { $0.id == host.id }) {
            entries.append(Entry(host, enrollmentToken: host.enrollmentCredential, modifiedAt: .distantPast))
        }
    }

    mutating func record(_ host: GatewayHostConfiguration, at time: Date) {
        guard let index = entries.firstIndex(where: { $0.id == host.id }) else {
            entries.append(Entry(host, enrollmentToken: host.enrollmentCredential, modifiedAt: time))
            return
        }
        let previous = entries[index]
        var updated = Entry(host, enrollmentToken: host.enrollmentCredential, modifiedAt: previous.modifiedAt)
        if updated.enrollmentToken == nil, previous.hasSameEndpoint(as: host) { updated.enrollmentToken = previous.enrollmentToken }
        guard updated != previous else { return }
        updated.modifiedAt = time
        entries[index] = updated
    }

    mutating func remove(_ id: UUID, at time: Date) {
        entries.removeAll { $0.id == id }
        deletions = Self.canonical(deletions.filter { $0.id != id } + [Deletion(id: id, deletedAt: time)])
    }

    mutating func fillEnrollmentCredentials(from seeds: [GatewayHostConfiguration]) {
        for index in entries.indices where entries[index].enrollmentToken == nil {
            let entry = entries[index]
            entries[index].enrollmentToken = seeds.first { $0.id == entry.id && entry.hasSameEndpoint(as: $0) }?
                .enrollmentCredential
        }
    }

    func merged(with remote: HostDirectory) -> HostDirectory {
        let deletions = Self.canonical(deletions + remote.deletions)
        let deletedAt = Dictionary(deletions.map { ($0.id, $0.deletedAt) }, uniquingKeysWith: max)
        let local = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>()
        var merged = HostDirectory()
        for entry in remote.entries + entries where seen.insert(entry.id).inserted {
            let mine = local[entry.id] ?? entry
            var winner = mine.modifiedAt > entry.modifiedAt ? mine : entry
            if winner.enrollmentToken == nil {
                let endpoint = winner.configuration(updating: nil)
                winner.enrollmentToken = [mine, entry].first { $0.hasSameEndpoint(as: endpoint) && $0.enrollmentToken != nil }?
                    .enrollmentToken
            }
            guard deletedAt[winner.id].map({ $0 < winner.modifiedAt }) ?? true else { continue }
            merged.entries.append(winner)
        }
        merged.deletions = deletions
        return merged
    }

    func configurations(updating device: [GatewayHostConfiguration]) -> [GatewayHostConfiguration] {
        let current = Dictionary(device.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return entries.map { $0.configuration(updating: current[$0.id]) }
    }

    private static func canonical(_ deletions: [Deletion]) -> [Deletion] {
        let latest = Dictionary(deletions.map { ($0.id, $0.deletedAt) }, uniquingKeysWith: max)
        return latest.map { Deletion(id: $0.key, deletedAt: $0.value) }
            .sorted { ($0.deletedAt, $0.id.uuidString) > ($1.deletedAt, $1.id.uuidString) }
            .prefix(deletionLimit)
            .map(\.self)
    }
}
