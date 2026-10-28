import Foundation
import Observation

@MainActor
@Observable
final class HostStore {
    private(set) var hosts: [ValidatedGatewayHost] = []
    private(set) var invalidHosts: [GatewayHostConfiguration] = []
    private(set) var activeHostID: UUID?
    private(set) var errorMessage: String?
    private(set) var syncFailure: String?
    private(set) var configurationIssue: String?
    private(set) var localConfiguration = LocalConfiguration()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: any GatewayCredentialStorage
    @ObservationIgnored private let sharedDirectory: SharedHostDirectory?
    @ObservationIgnored private var configurations: [GatewayHostConfiguration] = []
    @ObservationIgnored private var directory = HostDirectory()
    @ObservationIgnored private var isSaved = false
    @ObservationIgnored private var seedHosts: [GatewayHostConfiguration] = []
    @ObservationIgnored private var loadFailed = false
    @ObservationIgnored private var enrollmentTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var syncRequested = false

    nonisolated static let installationIDKey = "gateway.installationID"
    private static let hostsKey = "gateway.hosts"
    private static let activeHostIDKey = "gateway.activeHostID"

    private struct Snapshot: Codable {
        var hosts: [GatewayHostConfiguration]
        var activeHostID: UUID?
        var directory: HostDirectory?
    }

    struct SavedHosts {
        let configurations: [GatewayHostConfiguration]
        let activeHostID: UUID?
        let directory: HostDirectory
        let isSaved: Bool
        var hosts: [ValidatedGatewayHost] { configurations.compactMap(ValidatedGatewayHost.init) }
        var invalidHosts: [GatewayHostConfiguration] { configurations.filter { ValidatedGatewayHost($0) == nil } }
    }

    convenience init(defaults: UserDefaults = AppStorageScope.current.defaults, bundle: Bundle = .main) {
        self.init(defaults: defaults, credentials: KeychainGatewayCredentials(scope: .device),
            sharedDirectory: KeychainGatewayCredentials(scope: .iCloud),
            configuration: Result { try LocalConfiguration.load(bundle: bundle) })
    }

    init(defaults: UserDefaults, credentials: any GatewayCredentialStorage, sharedDirectory: any GatewayCredentialStorage,
         configuration: Result<LocalConfiguration, any Error>) {
        self.defaults = defaults
        self.credentials = credentials
        self.sharedDirectory = SharedHostDirectory(storage: sharedDirectory)
        switch configuration {
        case .success(let configuration):
            localConfiguration = configuration
            seedHosts = GatewayHostConfiguration.builtInDefaults(from: configuration)
        case .failure(let error):
            configurationIssue = error.localizedDescription
        }
        reload()
    }

    init(hosts: [GatewayHostConfiguration], activeHostID: UUID?, defaults: UserDefaults,
         credentials: any GatewayCredentialStorage) {
        self.defaults = defaults
        self.credentials = credentials
        sharedDirectory = nil
        var directory = HostDirectory()
        directory.adopt(hosts)
        _ = commit(hosts, activeHostID: activeHostID ?? hosts.first?.id, directory: directory)
    }

    var activeHost: ValidatedGatewayHost? {
        hosts.first(where: { $0.id == activeHostID }) ?? hosts.first
    }

    func reload() {
        do {
            let saved = try HostStore.load(defaults: defaults, credentials: credentials, seedHosts: seedHosts)
            apply(saved.configurations, activeHostID: saved.activeHostID, directory: saved.directory)
            isSaved = saved.isSaved
            loadFailed = false
            errorMessage = nil
        } catch {
            loadFailed = true
            errorMessage = error.localizedDescription
            return
        }
        requestSync()
    }

    func synchronize() async {
        requestSync()
        await syncTask?.value
    }

    static func load(
        defaults: UserDefaults,
        credentials: any GatewayCredentialStorage,
        seedHosts: [GatewayHostConfiguration] = []
    ) throws -> SavedHosts {
        let snapshot: Snapshot
        let isSaved: Bool
        if let protected = try credentials.read() {
            snapshot = try JSONDecoder().decode(Snapshot.self, from: protected)
            retirePlaintext(defaults)
            isSaved = true
        } else if let legacy = defaults.data(forKey: hostsKey) {
            let hosts = try JSONDecoder().decode([GatewayHostConfiguration].self, from: legacy)
            var directory = HostDirectory()
            directory.adopt(hosts)
            snapshot = Snapshot(hosts: hosts,
                activeHostID: defaults.string(forKey: activeHostIDKey).flatMap(UUID.init(uuidString:)), directory: directory)
            try save(hosts: hosts, activeHostID: snapshot.activeHostID, directory: directory, defaults: defaults,
                credentials: credentials)
            isSaved = true
        } else {
            let hosts = seedHosts.filter(\.isValid)
            snapshot = Snapshot(hosts: hosts, activeHostID: hosts.first?.id, directory: nil)
            isSaved = false
        }
        var directory = snapshot.directory ?? HostDirectory()
        directory.adopt(snapshot.hosts)
        let configurations = directory.configurations(updating: snapshot.hosts)
        return SavedHosts(configurations: configurations,
            activeHostID: activeHostID(snapshot.activeHostID, in: configurations), directory: directory, isSaved: isSaved)
    }

    static func save(hosts: [GatewayHostConfiguration], activeHostID: UUID?, directory: HostDirectory,
                     defaults: UserDefaults, credentials: any GatewayCredentialStorage) throws {
        let data = try JSONEncoder().encode(Snapshot(hosts: hosts, activeHostID: activeHostID, directory: directory))
        try credentials.write(data)
        guard try credentials.read() == data else { throw GatewayCredentialFailure.verificationFailed }
        // Only verified protected persistence retires the old migration source.
        retirePlaintext(defaults)
    }

    private static func retirePlaintext(_ defaults: UserDefaults) {
        defaults.removeObject(forKey: hostsKey)
        defaults.removeObject(forKey: activeHostIDKey)
    }

    private static func activeHostID(_ id: UUID?, in configurations: [GatewayHostConfiguration]) -> UUID? {
        let valid = configurations.compactMap(ValidatedGatewayHost.init)
        return valid.contains(where: { $0.id == id }) ? id : valid.first?.id
    }

    func enrollInstallationCredentials(using client: any GatewayCredentialEnrolling,
        canReplaceHost: @escaping @MainActor (UUID) -> Bool) async {
        if let enrollmentTask { await enrollmentTask.value; return }
        guard !loadFailed else { return }
        let task = Task<Void, Never> { [weak self] in
            await self?.performEnrollment(using: client, canReplaceHost: canReplaceHost)
        }
        enrollmentTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
        enrollmentTask = nil
    }

    private func performEnrollment(using client: any GatewayCredentialEnrolling,
        canReplaceHost: @MainActor (UUID) -> Bool) async {
        let installationID = defaults.string(forKey: Self.installationIDKey) ?? UUID().uuidString.lowercased()
        defaults.set(installationID, forKey: Self.installationIDKey)
        for captured in hosts where !captured.configuration.usesInstallationCredential {
            guard canReplaceHost(captured.id) else { continue }
            do {
                try Task.checkCancellation()
                let token = try await client.enroll(host: captured.configuration,
                    installationID: installationID + "-" + captured.id.uuidString.lowercased())
                try Task.checkCancellation()
                guard canReplaceHost(captured.id), let current = hosts.first(where: { $0.id == captured.id }),
                      current.hasSameConnection(as: captured.configuration) else { continue }
                var enrolled = current.configuration
                enrolled.authToken = token
                _ = upsert(enrolled)
            } catch is CancellationError { return }
            catch { errorMessage = error.localizedDescription }
        }
    }

    @discardableResult
    func setActiveHost(_ host: GatewayHostConfiguration) -> Bool {
        guard hosts.contains(where: { $0.id == host.id }) else { return false }
        return commit(configurations, activeHostID: host.id, directory: directory)
    }

    @discardableResult
    func upsert(_ host: GatewayHostConfiguration) -> Bool {
        guard host.isValid else {
            errorMessage = "A valid hostname, port (1–65535), and authorization token are required."
            return false
        }
        var updated = configurations
        var directory = directory
        if let index = updated.firstIndex(where: { $0.id == host.id }) {
            var replacement = host
            replacement.gatewayID = updated[index].gatewayID
            replacement.legacyIDs = updated[index].legacyIDs
            replacement.incomingCallHostID = updated[index].hasSameConnection(as: host) ? updated[index].incomingCallHostID : nil
            updated[index] = replacement
            directory.record(replacement, at: .now)
        } else {
            updated.append(host)
            directory.record(host, at: .now)
        }
        return commit(updated, activeHostID: activeHostID ?? host.id, directory: directory)
    }

    @discardableResult
    func delete(_ host: GatewayHostConfiguration) -> Bool {
        guard invalidHosts.contains(where: { $0.id == host.id }) || hosts.count > 1 else { return false }
        var directory = directory
        directory.remove(host.id, at: .now)
        return commit(configurations.filter { $0.id != host.id }, activeHostID: activeHostID, directory: directory)
    }

    func enrollIncomingCalls(host: GatewayHostConfiguration, serverHostID: UUID) throws {
        guard let index = configurations.firstIndex(where: { $0.id == host.id }),
              hosts.contains(where: { $0.id == host.id }),
              configurations[index].hasSameConnection(as: host) else { throw AgentIncomingCallError.unavailable }
        if let enrolledID = configurations[index].incomingCallHostID, enrolledID != serverHostID {
            throw AgentIncomingCallError.hostIdentityChanged
        }
        guard !hosts.contains(where: { $0.id != host.id && $0.incomingCallHostID == serverHostID }) else {
            throw AgentIncomingCallError.hostIdentityChanged
        }
        guard configurations[index].incomingCallHostID != serverHostID else { return }
        var updated = configurations
        updated[index].incomingCallHostID = serverHostID
        try persist(updated, activeHostID: activeHostID, directory: directory)
    }

    func verifyIdentity(_ identity: GatewayIdentity, for captured: GatewayHostConfiguration) throws {
        guard let current = configurations.first(where: { $0.id == captured.id }),
              current.hasSameConnection(as: captured) else { throw CancellationError() }
        if let known = current.gatewayID, known != identity.hostId { throw AgentIncomingCallError.hostIdentityChanged }
    }

    func adoptIdentity(_ identity: GatewayIdentity, for captured: GatewayHostConfiguration) throws {
        try verifyIdentity(identity, for: captured)
        let matching = configurations.filter { $0.id == captured.id || $0.gatewayID == identity.hostId || $0.id == identity.hostId }
        var host = matching.first { $0.id == identity.hostId } ?? captured
        if host.usesInstallationCredential, let operatorHost = matching.first(where: { !$0.usesInstallationCredential }) {
            host = operatorHost
        }
        host.id = identity.hostId
        host.gatewayID = identity.hostId
        host.legacyIDs = Array(Set(matching.flatMap { [$0.id] + $0.legacyIDs }).subtracting([identity.hostId]))
            .sorted { $0.uuidString < $1.uuidString }
        var directory = directory
        for old in matching where old.id != host.id { directory.remove(old.id, at: .now) }
        directory.record(host, at: .now)
        let matchingIDs = Set(matching.map(\.id))
        let active = activeHostID.map { matchingIDs.contains($0) ? host.id : $0 }
        try persist(configurations.filter { !matchingIDs.contains($0.id) } + [host], activeHostID: active, directory: directory)
        for old in host.legacyIDs { GatewayIdentityPreferences.migrate(from: old, to: host.id, defaults: defaults) }
        requestSync()
    }

    private func commit(_ configurations: [GatewayHostConfiguration], activeHostID: UUID?, directory: HostDirectory) -> Bool {
        let directoryChanged = directory != self.directory
        do {
            try persist(configurations, activeHostID: activeHostID, directory: directory)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        if directoryChanged { requestSync() }
        return true
    }

    private func persist(_ configurations: [GatewayHostConfiguration], activeHostID: UUID?, directory: HostDirectory) throws {
        guard !loadFailed else { throw GatewayCredentialFailure.configurationUnavailable }
        let activeHostID = Self.activeHostID(activeHostID, in: configurations)
        try HostStore.save(hosts: configurations, activeHostID: activeHostID, directory: directory, defaults: defaults,
            credentials: credentials)
        isSaved = true
        apply(configurations, activeHostID: activeHostID, directory: directory)
    }

    private func apply(_ configurations: [GatewayHostConfiguration], activeHostID: UUID?, directory: HostDirectory) {
        let valid = configurations.compactMap(ValidatedGatewayHost.init)
        let invalid = configurations.filter { ValidatedGatewayHost($0) == nil }
        self.configurations = configurations
        self.directory = directory
        if hosts != valid { hosts = valid }
        if invalidHosts != invalid { invalidHosts = invalid }
        if self.activeHostID != activeHostID { self.activeHostID = activeHostID }
    }

    private func requestSync() {
        guard sharedDirectory != nil else { return }
        syncRequested = true
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in
            while let self, syncRequested {
                syncRequested = false
                await runSync()
            }
            self?.syncTask = nil
        }
    }

    private func runSync() async {
        guard let sharedDirectory, !loadFailed else { return }
        do {
            let shared = try await sharedDirectory.read()
            guard !loadFailed, shared != nil || isSaved else { return }
            var merged = shared.map { directory.merged(with: $0) } ?? directory
            merged.fillEnrollmentCredentials(from: seedHosts)
            let synced = merged.configurations(updating: configurations)
            if merged != directory || synced != configurations {
                try persist(synced, activeHostID: activeHostID, directory: merged)
            }
            if merged != shared {
                let replaced = try await sharedDirectory.replace(shared, with: merged)
                if !replaced { syncRequested = true }
            }
            syncFailure = nil
        } catch {
            syncFailure = error.localizedDescription
        }
    }
}
