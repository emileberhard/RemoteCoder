@preconcurrency import ActivityKit
import Foundation
import OSLog

/// Owns one aggregate "active tasks" activity for a single gateway host.
///
/// Every lookup and end is filtered to that host. The app only requests the
/// activity and registers its push token; the host's gateway authors its
/// content and ends it, so it stays correct while the app is suspended.
actor ActiveTasksLiveActivityService {
    private let logger = AppLogger(category: "ActiveTasksLiveActivity")

    private let hostID: UUID
    private let legacyHostIDs: Set<UUID>
    private let hostName: String
    private var observedPushTokenActivityID: String?
    private var pushTokenObserverTask: Task<Void, Never>?
    private var lastPushTokenHex: String?
    private var snapshot: ActiveTasksLiveActivitySnapshot?
    private var snapshotGeneration: UInt64 = 0

    init(hostID: UUID, hostName: String, legacyHostIDs: Set<UUID>) {
        self.hostID = hostID
        self.legacyHostIDs = legacyHostIDs
        self.hostName = hostName
    }

    func sync(
        requestsActivity: Bool,
        now: Date,
        onPushTokenUpdate: @escaping @Sendable (String) async -> Void,
        onEnded: @escaping @Sendable () async -> Void
    ) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.notice("sync ending all activities because activities are disabled")
            await endActivities(onEnded: onEnded)
            return
        }

        if let activity = currentActivity() {
            ensurePushTokenObserver(activity: activity, onPushTokenUpdate: onPushTokenUpdate)
            return
        }
        guard requestsActivity, snapshot?.content.isEmpty == false else { return }

        // A nil-host activity belongs to an earlier build; retire it before
        // requesting this host's own, so the lock screen never shows both.
        await endLegacyActivities()
        guard !Task.isCancelled, let snapshot, !snapshot.content.isEmpty else { return }

        do {
            let attributes = RemoteCoderActiveTasksAttributes(
                startedAt: now,
                hostID: hostID,
                hostName: hostName
            )
            let state = RemoteCoderActiveTasksAttributes.ContentState(
                activeTaskCount: snapshot.content.activeTaskCount,
                attention: snapshot.content.attention,
                attentionCount: snapshot.content.attentionCount,
                updatedAtUnixSeconds: snapshot.updatedAtUnixSeconds
            )
            let activity = try Activity<RemoteCoderActiveTasksAttributes>.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: now.addingTimeInterval(300), relevanceScore: snapshot.relevanceScore),
                pushType: .token
            )
            ensurePushTokenObserver(activity: activity, onPushTokenUpdate: onPushTokenUpdate)
            logger.notice("Started active-tasks live activity id=\(activity.id) count=\(state.activeTaskCount)")
        } catch {
            logger.error("Failed to start active-tasks live activity: \(String(describing: error))")
        }
    }

    func end() async {
        await endActivities(onEnded: nil)
    }

    func refresh(using read: @Sendable () async throws -> ActiveTasksLiveActivitySnapshot?) async throws {
        receive(nil)
        let generation = snapshotGeneration
        let incoming = try await read()
        guard !Task.isCancelled, snapshotGeneration == generation else { return }
        receive(incoming)
    }

    func receive(_ incoming: ActiveTasksLiveActivitySnapshot?) {
        if let snapshot, let incoming, snapshot.epoch == incoming.epoch, snapshot.revision >= incoming.revision { return }
        snapshotGeneration += 1
        snapshot = incoming
    }

    private func currentActivity() -> Activity<RemoteCoderActiveTasksAttributes>? {
        Activity<RemoteCoderActiveTasksAttributes>.activities.first {
            ActiveTasksLiveActivityScope.owns(activityHostID: $0.attributes.hostID, serviceHostID: hostID)
                && [.active, .stale].contains($0.activityState)
        }
    }

    private func endLegacyActivities() async {
        let legacy = Activity<RemoteCoderActiveTasksAttributes>.activities.filter {
            ActiveTasksLiveActivityScope.isLegacy(activityHostID: $0.attributes.hostID)
                || $0.attributes.hostID.map { legacyHostIDs.contains($0) } == true
        }
        guard legacy.isEmpty == false else { return }
        for activity in legacy {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        logger.notice("Retired \(legacy.count) pre-multi-host live activities")
    }

    private func endActivities(onEnded: (@Sendable () async -> Void)?) async {
        let activities = Activity<RemoteCoderActiveTasksAttributes>.activities.filter {
            ActiveTasksLiveActivityScope.mayEnd(activityHostID: $0.attributes.hostID, serviceHostID: hostID)
        }
        observedPushTokenActivityID = nil
        pushTokenObserverTask?.cancel()
        pushTokenObserverTask = nil
        lastPushTokenHex = nil
        guard activities.isEmpty == false else { return }

        for activity in activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        if let onEnded {
            await onEnded()
        }
        logger.notice(
            "Ended \(activities.count) active-tasks live activities for \(self.hostName)"
        )
    }

    private func ensurePushTokenObserver(
        activity: Activity<RemoteCoderActiveTasksAttributes>,
        onPushTokenUpdate: @escaping @Sendable (String) async -> Void
    ) {
        let activityID = activity.id
        if observedPushTokenActivityID == activityID, pushTokenObserverTask != nil {
            return
        }

        observedPushTokenActivityID = activityID
        pushTokenObserverTask?.cancel()
        pushTokenObserverTask = Task { [weak self] in
            for await token in activity.pushTokenUpdates {
                guard Task.isCancelled == false else { return }
                let hex = token.map { String(format: "%02x", $0) }.joined()
                await self?.handlePushTokenUpdate(hex, onPushTokenUpdate: onPushTokenUpdate)
            }
        }
    }

    private func handlePushTokenUpdate(
        _ tokenHex: String,
        onPushTokenUpdate: @Sendable (String) async -> Void
    ) async {
        let trimmed = tokenHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        guard trimmed != lastPushTokenHex else { return }
        lastPushTokenHex = trimmed
        await onPushTokenUpdate(trimmed)
    }
}
