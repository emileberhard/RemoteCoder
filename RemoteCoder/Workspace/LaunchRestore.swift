import Foundation
import OSLog

enum LaunchLocation: Equatable {
    case conversation(ConversationAddress)
    case newChat(UnsentDraftAddress)
}

@MainActor
protocol LaunchRestoreHost: AnyObject {
    var openLocation: LaunchLocation? { get }
    var hasPendingNotificationTap: Bool { get }
    func launchOwner(of address: ConversationAddress) -> ChatTargetModel?
    func showRestored(_ thread: ConversationHeader, on owner: ChatTargetModel, at address: ConversationAddress)
    func showRestoredNewChat(on target: ExecutionTarget)
}

@MainActor
final class LaunchRestore {
    private enum Phase {
        case awaitingBootstrap(LaunchLocation?)
        case restoring
        case settled
    }

    private static let key = "workspace.open-conversation.v1"

    private var phase: Phase
    private var task: Task<Void, Never>?
    private let defaults: UserDefaults
    private let loadHeader: @MainActor (ChatTargetModel, String) async throws -> ConversationHeader
    private let logger = Logger(subsystem: "RemoteCoder", category: "LaunchRestore")

    init(defaults: UserDefaults,
         loadHeader: @escaping @MainActor (ChatTargetModel, String) async throws -> ConversationHeader) {
        self.defaults = defaults
        self.loadHeader = loadHeader
        phase = .awaitingBootstrap(Self.recorded(in: defaults))
    }

    func newChatDraft(on target: ExecutionTarget) -> UUID? {
        guard case .awaitingBootstrap(.newChat(let draft)) = phase, draft.target == target else { return nil }
        return draft.draftID
    }

    func restore(using host: any LaunchRestoreHost) {
        guard case .awaitingBootstrap(let location) = phase else { return }
        if case .newChat(let draft) = location, !host.hasPendingNotificationTap {
            host.showRestoredNewChat(on: draft.target)
        }
        guard case .conversation(let recorded) = location, !host.hasPendingNotificationTap,
              let owner = host.launchOwner(of: recorded) else {
            settle(recording: host.openLocation)
            return
        }
        phase = .restoring
        let loadHeader = loadHeader
        task = Task { [weak self, weak host] in
            let header: Result<ConversationHeader, any Error>
            do {
                header = .success(try await loadHeader(owner, recorded.threadID))
            } catch {
                header = .failure(error)
            }
            guard let self, let host, case .restoring = self.phase else { return }
            self.task = nil
            self.settle(recording: host.openLocation)
            let thread: ConversationHeader
            switch header {
            case .success(let loaded): thread = loaded
            case .failure(let error):
                self.logger.notice("launch restore skipped thread=\(recorded.threadID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                return
            }
            guard thread.id == recorded.threadID, !owner.isRetired,
                  host.launchOwner(of: recorded) === owner else { return }
            host.showRestored(thread, on: owner, at: recorded)
        }
    }

    func settle(recording open: LaunchLocation?) {
        if case .settled = phase { return }
        task?.cancel()
        task = nil
        phase = .settled
        record(open)
    }

    func record(_ open: LaunchLocation?) {
        guard case .settled = phase else { return }
        let record = open.map { location in
            switch location {
            case .conversation(let address):
                let record = ["host": address.hostID.uuidString, "thread": address.threadID]
                return record
            case .newChat(let draft):
                let record = ["host": draft.target.hostID.uuidString, "draft": draft.draftID.uuidString]
                return record
            }
        }
        guard defaults.dictionary(forKey: Self.key) as? [String: String] != record else { return }
        defaults.set(record, forKey: Self.key)
    }

    private static func recorded(in defaults: UserDefaults) -> LaunchLocation? {
        guard let record = defaults.dictionary(forKey: key) as? [String: String],
              let hostID = record["host"].flatMap(UUID.init(uuidString:)) else { return nil }
        if let threadID = record["thread"] {
            return .conversation(ConversationAddress(hostID: hostID, threadID: threadID))
        }
        guard let draftID = record["draft"].flatMap(UUID.init(uuidString:)) else { return nil }
        let slot = record["account"].flatMap(UUID.init(uuidString:)).map {
            AccountRetirementMigration.draftSlot(hostID: hostID, accountID: $0, slot: draftID)
        } ?? draftID
        return .newChat(UnsentDraftAddress(target: ExecutionTarget(hostID: hostID), draftID: slot))
    }
}
