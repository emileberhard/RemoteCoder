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
    private(set) var identityMigration: GatewayIdentityImport?
    @ObservationIgnored private var completingIdentityMigration = false
    private(set) var localConfiguration = LocalConfiguration()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let defaultsDomain: String
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
        var identityMigration: GatewayIdentityImport?
    }

    struct SavedHosts {
        let configurations: [GatewayHostConfiguration]
        let activeHostID: UUID?
        let directory: HostDirectory
        let isSaved: Bool
        let identityMigration: GatewayIdentityImport?
        var hosts: [ValidatedGatewayHost] { configurations.compactMap(ValidatedGatewayHost.init) }
        var invalidHosts: [GatewayHostConfiguration] { configurations.filter { ValidatedGatewayHost($0) == nil } }
    }

    convenience init(defaults: UserDefaults = AppStorageScope.current.defaults, bundle: Bundle = .main) {
        self.init(defaults: defaults, credentials: KeychainGatewayCredentials(scope: .device),
            sharedDirectory: KeychainGatewayCredentials(scope: .iCloud),
            configuration: Result { try LocalConfiguration.load(bundle: bundle) })
    }

    init(defaults: UserDefaults, credentials: any GatewayCredentialStorage, sharedDirectory: any GatewayCredentialStorage,
         configuration: Result<LocalConfiguration, any Error>, defaultsDomain: String = AppStorageScope.current.defaultsDomainName) {
        self.defaults = defaults
        self.defaultsDomain = defaultsDomain
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
         credentials: any GatewayCredentialStorage, defaultsDomain: String = AppStorageScope.current.defaultsDomainName) {
        self.defaults = defaults
        self.defaultsDomain = defaultsDomain
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
            identityMigration = saved.identityMigration
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
            activeHostID: activeHostID(snapshot.activeHostID, in: configurations), directory: directory, isSaved: isSaved, identityMigration: snapshot.identityMigration)
    }

    static func save(hosts: [GatewayHostConfiguration], activeHostID: UUID?, directory: HostDirectory,
                     defaults: UserDefaults, credentials: any GatewayCredentialStorage, identityMigration: GatewayIdentityImport? = nil) throws {
        let data = try JSONEncoder().encode(Snapshot(hosts: hosts, activeHostID: activeHostID, directory: directory, identityMigration: identityMigration))
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
            guard !identityMigrationHostIDs.contains(captured.id), canReplaceHost(captured.id) else { continue }
            do {
                try Task.checkCancellation()
                let token = try await client.enroll(host: captured.configuration,
                    installationID: installationID + "-" + captured.id.uuidString.lowercased())
                try Task.checkCancellation()
                guard !identityMigrationHostIDs.contains(captured.id), canReplaceHost(captured.id), let current = hosts.first(where: { $0.id == captured.id }),
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
        guard !identityMigrationHostIDs.contains(host.id) else {
            errorMessage = "Saved gateway state is importing. Retry after the import finishes."
            return false
        }
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
        guard !identityMigrationHostIDs.contains(host.id),
              invalidHosts.contains(where: { $0.id == host.id }) || hosts.count > 1 else { return false }
        var directory = directory
        directory.remove(host.id, at: .now)
        return commit(configurations.filter { $0.id != host.id }, activeHostID: activeHostID, directory: directory)
    }

    func enrollIncomingCalls(host: GatewayHostConfiguration, serverHostID: UUID) throws {
        guard !identityMigrationHostIDs.contains(host.id) else { throw GatewayIdentityMigration.MigrationFailure.verificationInProgress }
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

    private func identityConfigurations(_ identity: GatewayIdentity, for captured: GatewayHostConfiguration) throws -> [GatewayHostConfiguration] {
        try verifyIdentity(identity, for: captured)
        return configurations.filter { $0.id == captured.id || $0.gatewayID == identity.hostId || $0.id == identity.hostId }
    }

    func identityMigrationHosts(_ identity: GatewayIdentity, for captured: GatewayHostConfiguration) throws -> Set<UUID> {
        Set(try identityConfigurations(identity, for: captured).flatMap { [$0.id] + $0.legacyIDs }).union([identity.hostId])
    }

    var identityMigrationHostIDs: Set<UUID> { identityMigration?.fencedHostIDs ?? [] }

    func beginIdentityMigration(_ identity: GatewayIdentity, for captured: GatewayHostConfiguration) throws {
        guard identityMigration == nil, !completingIdentityMigration else { throw GatewayIdentityMigration.MigrationFailure.verificationInProgress }
        let matching = try identityConfigurations(identity, for: captured)
        var host = matching.first { $0.id == identity.hostId } ?? captured
        if host.usesInstallationCredential, let operatorHost = matching.first(where: { !$0.usesInstallationCredential }) {
            host = operatorHost
        }
        host.id = identity.hostId
        host.gatewayID = identity.hostId
        host.legacyIDs = Array(Set(matching.flatMap { [$0.id] + $0.legacyIDs }).subtracting([identity.hostId]))
            .sorted { $0.uuidString < $1.uuidString }
        identityMigration = .init(id: UUID(), host: host, replacedIDs: Set(matching.map(\.id)))
        do { try persist(configurations, activeHostID: activeHostID, directory: directory) }
        catch { errorMessage = error.localizedDescription; throw error }
    }

    func completeIdentityMigration(using migration: GatewayIdentityMigration) async throws {
        guard let journal = identityMigration else { return }
        guard !completingIdentityMigration else { throw GatewayIdentityMigration.MigrationFailure.verificationInProgress }
        completingIdentityMigration = true
        defer { completingIdentityMigration = false }
        do {
            try persist(configurations, activeHostID: activeHostID, directory: directory)
            try await migration.migrate(journal)
            try Task.checkCancellation()
            var directory = directory
            for id in journal.replacedIDs where id != journal.host.id { directory.remove(id, at: .now) }
            directory.record(journal.host, at: .now)
            let active = activeHostID.map { journal.replacedIDs.contains($0) ? journal.host.id : $0 }
            try persist(configurations.filter { !journal.replacedIDs.contains($0.id) && $0.id != journal.host.id } + [journal.host],
                        activeHostID: active, directory: directory)
            for source in journal.host.legacyIDs {
                try await GatewayIdentityPreferences.migrate(from: source, to: journal.host.id, domainName: defaultsDomain)
            }
            try Task.checkCancellation()
            try await migration.finish(journal)
            identityMigration = nil
            do { try persist(configurations, activeHostID: activeHostID, directory: directory) }
            catch { identityMigration = journal; throw error }
            errorMessage = nil
            requestSync()
        } catch {
            errorMessage = "Saved gateway state could not finish importing: \(error.localizedDescription)"
            throw error
        }
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
            credentials: credentials, identityMigration: identityMigration)
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
        guard let sharedDirectory, !loadFailed, identityMigration == nil else { return }
        do {
            let shared = try await sharedDirectory.read()
            guard !loadFailed, identityMigration == nil, shared != nil || isSaved else { return }
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
