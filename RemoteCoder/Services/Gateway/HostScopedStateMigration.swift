import Foundation
import OSLog

/// Splits the pre-multi-host local state across the configured hosts, exactly
/// once.
///
/// Only data with a provable owner moves. Copying an ambiguous mapping into
/// every host would, for example, point one gateway's chat at another machine's
/// missing repository, so anything unattributable is left where it is and the
/// host-scoped cache is rebuilt from authoritative remote history instead.
///
/// This runs synchronously, from `ChatWorkspaceModel.init`, before the first
/// chat model exists. Its consumers — the session index actor, the pin store and
/// the working-directory default — all read their state once when they are
/// constructed, so a migration that landed afterwards would be overwritten by
/// the very stores it was meant to seed.
@MainActor
enum HostScopedStateMigration {
    private static let completedKey = "gateway.hostScopedStateMigrated"
    private static let logger = Logger(subsystem: "RemoteCoder", category: "HostScopedMigration")

    @discardableResult
    static func runIfNeeded(
        hosts: [GatewayHostConfiguration],
        activeHostID: UUID?,
        bundledWorkingDirectory: String? = nil,
        defaults: UserDefaults = AppStorageScope.current.defaults,
        historyDirectory: URL? = nil,
        legacyStorageDirectory: URL? = nil,
        storage: HostStorage = .live
    ) -> String? {
        guard defaults.bool(forKey: completedKey) == false else { return nil }
        guard hosts.isEmpty == false else { return nil }

        var threadOwners: [String: [UUID]] = [:]
        for host in hosts {
            let threadIDs = ConversationHeaderStore.cachedThreadIDs(
                hostID: host.id,
                baseDirectory: historyDirectory,
                storage: storage
            )
            for threadID in threadIDs {
                threadOwners[threadID, default: []].append(host.id)
            }
        }

        migrateWorkingDirectory(hosts: hosts, activeHostID: activeHostID,
            bundledWorkingDirectory: bundledWorkingDirectory, defaults: defaults)
        let pinResult = migratePins(threadOwners: threadOwners, defaults: defaults)
        let indexResult = migrateSessionIndex(
            threadOwners: threadOwners,
            legacyStorageDirectory: legacyStorageDirectory,
            storage: storage
        )

        defaults.set(true, forKey: completedKey)

        var limitations: [String] = []
        if pinResult.unattributed > 0 {
            limitations.append("\(pinResult.unattributed) pinned chat(s) had no unique host in the cached history and stayed in the shared store")
        }
        if indexResult.unattributed > 0 {
            limitations.append("\(indexResult.unattributed) session-to-conversation mapping(s) had no unique host and were left unscoped, so those chats get fresh local timelines")
        }
        let limitation = limitations.isEmpty ? nil : limitations.joined(separator: "; ")
        logger.notice(
            "host-scoped migration complete pins=\(pinResult.migrated, privacy: .public) sessions=\(indexResult.migrated, privacy: .public) limitation=\(limitation ?? "none", privacy: .public)"
        )
        return limitation
    }

    /// The single unscoped working directory belonged to whichever host was
    /// active when the app was upgraded; that host is its unique owner. The
    /// bundled `codexWorkdir` is the same kind of single-machine value, so it
    /// seeds that one host too and never the others.
    private static func migrateWorkingDirectory(
        hosts: [GatewayHostConfiguration],
        activeHostID: UUID?,
        bundledWorkingDirectory: String?,
        defaults: UserDefaults
    ) {
        guard let ownerID = activeHostID ?? hosts.first?.id else { return }
        let legacy = defaults.string(forKey: HostPreferences.workingDirectoryKey(hostID: nil))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bundled = bundledWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let adopted = (legacy?.isEmpty == false ? legacy : nil) ?? (bundled?.isEmpty == false ? bundled : nil)
        else { return }
        let scopedKey = HostPreferences.workingDirectoryKey(hostID: ownerID)
        guard defaults.string(forKey: scopedKey) == nil else { return }
        defaults.set(adopted, forKey: scopedKey)
    }

    private static func migratePins(
        threadOwners: [String: [UUID]],
        defaults: UserDefaults
    ) -> (migrated: Int, unattributed: Int) {
        let legacyStore = ConversationPinStore.scoped(hostID: nil, defaults: defaults)
        let legacyPins = legacyStore.load()
        guard legacyPins.isEmpty == false else { return (0, 0) }

        var adopted: [UUID: [String: String]] = [:]
        var unattributed = 0
        for (threadID, name) in legacyPins {
            guard let owners = threadOwners[threadID], owners.count == 1 else {
                unattributed += 1
                continue
            }
            adopted[owners[0], default: [:]][threadID] = name
        }

        var migrated = 0
        for (hostID, pins) in adopted {
            let store = ConversationPinStore.scoped(hostID: hostID, defaults: defaults)
            var existing = store.load()
            for (threadID, name) in pins where existing[threadID] == nil {
                existing[threadID] = name
                migrated += 1
            }
            store.save(existing)
        }
        return (migrated, unattributed)
    }

    /// Keeps persisted timelines attached to their conversations: the timeline
    /// store is keyed by local conversation UUID, so a thread that loses its
    /// mapping renders an empty history until it runs again.
    private static func migrateSessionIndex(
        threadOwners: [String: [UUID]],
        legacyStorageDirectory: URL?,
        storage: HostStorage
    ) -> (migrated: Int, unattributed: Int) {
        let legacyEntries = ConversationIndex.legacyEntriesSynchronously(directory: legacyStorageDirectory, storage: storage)
        guard legacyEntries.isEmpty == false else { return (0, 0) }

        var adopted: [UUID: [String: UUID]] = [:]
        var unattributed = 0
        for (threadID, conversationID) in legacyEntries {
            guard let owners = threadOwners[threadID], owners.count == 1 else {
                unattributed += 1
                continue
            }
            adopted[owners[0], default: [:]][threadID] = conversationID
        }

        var migrated = 0
        for (hostID, entries) in adopted {
            ConversationIndex.adoptSynchronously(entries, hostID: hostID, storage: storage)
            migrated += entries.count
        }
        return (migrated, unattributed)
    }
}
