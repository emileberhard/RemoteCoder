import Foundation
import Observation

@Observable @MainActor
final class AccountResetRedemptions {
    typealias BeginBackgroundExecution = @MainActor (@escaping @MainActor () -> Void) -> (@MainActor () -> Void)
    private(set) var states: [String: ResetRedemptionState] = [:]
    private(set) var error: String?
    private(set) var isRestored = false
    @ObservationIgnored private let store: ResetRedemptionStore
    @ObservationIgnored private let beginBackgroundExecution: BeginBackgroundExecution
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var taskIDs: [String: UUID] = [:]
    @ObservationIgnored private var hostIDs: Set<UUID>?
    @ObservationIgnored private(set) var revision = UUID()
    @ObservationIgnored private var resumptions: [UUID: Int] = [:]
    @ObservationIgnored private let log = AppLogger(category: "AccountResets")

    init(storage: HostStorage, provider: AgentProvider, beginBackgroundExecution: @escaping BeginBackgroundExecution) {
        store = ResetRedemptionStore(storage: storage, provider: provider)
        self.beginBackgroundExecution = beginBackgroundExecution
    }

    func restore() async {
        guard !isRestored else { return }
        do {
            let pending = try await store.load()
            guard !isRestored else { return }
            states = pending.mapValues(ResetRedemptionState.init(restoring:))
            isRestored = true
            error = nil
            if let hostIDs { retainHosts(hostIDs) }
        } catch { self.error = "Could not read pending resets: \(error.localizedDescription)" }
    }

    func redeem(accountID: String, accountName: String, hostID: UUID, gatewayAccountID: String, offer: AccountResetOffer,
                operation: @escaping @MainActor (ResetRedemptionAttempt) async throws -> AccountResetRedemptionResult,
                refresh: @escaping @MainActor () async -> Void) async {
        let fence = revision
        await restore()
        guard isRestored, revision == fence, !Task.isCancelled, hostIDs?.contains(hostID) != false else { return }
        guard let attempt = states[accountID, default: .idle].begin(offer: offer, key: UUID(), hostID: hostID,
                                                                   gatewayAccountID: gatewayAccountID, accountName: accountName) else { return }
        await run(accountID: accountID, attempt: attempt, operation: operation, refresh: refresh)
    }

    func retry(accountID: String,
               operation: @escaping @MainActor (ResetRedemptionAttempt) async throws -> AccountResetRedemptionResult,
               refresh: @escaping @MainActor () async -> Void) async {
        let fence = revision
        await restore()
        guard isRestored, revision == fence, !Task.isCancelled else { return }
        guard let attempt = states[accountID, default: .idle].retry() else { return }
        await run(accountID: accountID, attempt: attempt, operation: operation, refresh: refresh)
    }

    func resume(now: Date, fence: UUID,
                operation: @escaping @MainActor (String, ResetRedemptionAttempt) async throws -> AccountResetRedemptionResult,
                refresh: @escaping @MainActor () async -> Void) {
        guard isRestored, revision == fence else { return }
        for accountID in states.keys.sorted() {
            guard case .unconfirmed(let pending, _) = states[accountID], pending.canResume(now: now),
                  resumptions[pending.idempotencyKey, default: 0] < 3,
                  let attempt = states[accountID]?.retry() else { continue }
            resumptions[attempt.idempotencyKey, default: 0] += 1
            start(accountID: accountID, attempt: attempt, operation: { try await operation(accountID, $0) }, refresh: refresh)
        }
    }

    private func run(accountID: String, attempt: ResetRedemptionAttempt,
                     operation: @escaping @MainActor (ResetRedemptionAttempt) async throws -> AccountResetRedemptionResult,
                     refresh: @escaping @MainActor () async -> Void) async {
        await start(accountID: accountID, attempt: attempt, operation: operation, refresh: refresh).value
    }

    @discardableResult
    private func start(accountID: String, attempt: ResetRedemptionAttempt,
                       operation: @escaping @MainActor (ResetRedemptionAttempt) async throws -> AccountResetRedemptionResult,
                       refresh: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        log.notice("reset submission started account=\(accountID) reset=\(attempt.resetId) key=\(attempt.canonicalIdempotencyKey.prefix(8))")
        let taskID = UUID()
        taskIDs[accountID] = taskID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let release = beginBackgroundExecution { [weak self] in
                guard let self, taskIDs[accountID] == taskID else { return }
                cancel(accountID: accountID)
            }
            defer {
                release()
                if taskIDs[accountID] == taskID {
                    taskIDs.removeValue(forKey: accountID)
                    tasks.removeValue(forKey: accountID)
                }
            }
            do {
                try await store.save(attempt, accountID: accountID)
            } catch {
                guard taskIDs[accountID] == taskID else { return }
                states[accountID]?.fail("Could not save reset attempt: \(error.localizedDescription)",
                                        key: attempt.idempotencyKey, unconfirmed: false)
                await refresh()
                return
            }
            guard !Task.isCancelled, taskIDs[accountID] == taskID, var next = states[accountID] else { return }
            do {
                let result = try await operation(attempt)
                next.resolve(result, key: attempt.idempotencyKey)
            } catch {
                let failure = error as? ResetRedemptionError
                let unsubmittedRetry = failure?.isUnavailable == true && attempt == next.retryingAttempt
                let unconfirmed = unsubmittedRetry || (failure?.isUnconfirmed ?? (error is CancellationError))
                if unsubmittedRetry, let charged = resumptions[attempt.idempotencyKey] {
                    resumptions[attempt.idempotencyKey] = max(0, charged - 1)
                }
                next.fail(error.localizedDescription, key: attempt.idempotencyKey, unconfirmed: unconfirmed)
            }
            guard !Task.isCancelled, taskIDs[accountID] == taskID else { return }
            log.notice("reset submission finished account=\(accountID) key=\(attempt.canonicalIdempotencyKey.prefix(8)) state=\(next.message ?? "none")")
            if !next.isUnresolved {
                do {
                    try await store.resolve(accountID: accountID, key: attempt.idempotencyKey)
                    resumptions.removeValue(forKey: attempt.idempotencyKey)
                } catch {
                    next = .unconfirmed(attempt, "Could not save the reset result: \(error.localizedDescription)")
                }
            }
            guard !Task.isCancelled, taskIDs[accountID] == taskID else { return }
            states[accountID] = next
            await refresh()
        }
        tasks[accountID] = task
        return task
    }

    private func cancel(accountID: String) {
        tasks.removeValue(forKey: accountID)?.cancel()
        taskIDs.removeValue(forKey: accountID)
        if let key = states[accountID]?.attempt?.idempotencyKey {
            log.notice("reset submission cancelled account=\(accountID) key=\(key.uuidString.lowercased().prefix(8))")
            states[accountID]?.fail(ResetRedemptionState.unconfirmedMessage, key: key, unconfirmed: true)
        }
    }

    func stop() {
        revision = UUID()
        for id in Array(tasks.keys) { cancel(accountID: id) }
    }

    func retire(hostID: UUID) {
        for (id, state) in states where state.attempt?.hostID == hostID {
            cancel(accountID: id)
        }
    }

    func retainHosts(_ ids: Set<UUID>) {
        hostIDs = ids
        for hostID in Set(states.values.compactMap { $0.attempt?.hostID }).subtracting(ids) { retire(hostID: hostID) }
    }

    func retainAccounts(_ ids: Set<String>) {
        for (id, state) in states where !ids.contains(id) {
            if state.isUnresolved {
                cancel(accountID: id)
            } else { states.removeValue(forKey: id) }
        }
    }

    func forget(accountID: String) async {
        guard let state = states[accountID], state.canForget, let attempt = state.attempt else { return }
        do {
            try await store.resolve(accountID: accountID, key: attempt.idempotencyKey)
            guard states[accountID] == state else { return }
            states[accountID] = .failed("Reset forgotten. Its outcome is still unknown.")
        } catch { self.error = "Could not forget reset: \(error.localizedDescription)" }
    }
}
