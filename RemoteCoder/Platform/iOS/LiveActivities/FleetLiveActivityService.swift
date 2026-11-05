@preconcurrency import ActivityKit
import Foundation

@MainActor
final class FleetLiveActivityService {
    struct Host: Sendable {
        let id: UUID
        let isCoordinatorCapable: @MainActor () async -> Bool
        let read: @MainActor ([UUID]) async throws -> ActiveTasksLiveActivitySnapshot
        let register: @MainActor (DeviceRegistrationRequest.FleetActivity?) -> Void
    }

    enum Scene {
        case active, inactive, background
    }

    private typealias Attributes = RemoteCoderActiveTasksAttributes

    private let logger = AppLogger(category: "FleetLiveActivity")
    private let hosts: @MainActor () -> [Host]
    private let configured: @MainActor () -> [UUID]
    private let preferred: @MainActor () -> UUID?
    private var scene = Scene.active
    private var activity: Activity<Attributes>?
    private var token: String?
    private var coordinatorID: UUID?
    private var hasRestored = false
    private var awaitsEmpty = false
    private var observers: [Task<Void, Never>] = []
    private var pass: Task<Void, Never>?
    private var passRequested = false
    private var isRetired = false

    init(
        hosts: @escaping @MainActor () -> [Host],
        configured: @escaping @MainActor () -> [UUID],
        preferred: @escaping @MainActor () -> UUID?
    ) {
        self.hosts = hosts
        self.configured = configured
        self.preferred = preferred
    }

    func sceneChanged(_ next: Scene) {
        scene = next
        schedule()
    }

    func schedule() {
        guard !isRetired else { return }
        passRequested = true
        guard pass == nil else { return }
        pass = Task { [weak self] in
            while let self, self.passRequested, !self.isRetired {
                self.passRequested = false
                await self.run()
            }
            self?.pass = nil
        }
    }

    func settle() async {
        schedule()
        while let pass { await pass.value }
    }

    func retire() {
        isRetired = true
        pass?.cancel()
        for observer in observers { observer.cancel() }
        observers.removeAll()
    }

    private func run() async {
        await restoreIfNeeded()
        let declared = configured()
        let hosts = hosts()
        if let activity, ![.active, .stale].contains(activity.activityState) {
            if activity.activityState == .dismissed { awaitsEmpty = true }
            logger.notice("fleet activity left id=\(activity.id) state=\(String(describing: activity.activityState))")
            drop(activity)
        }
        if let activity {
            await maintain(activity, hosts: hosts, declared: declared)
            return
        }
        guard scene != .background, !isRetired else { return }
        var failed: Set<UUID> = []
        while let coordinator = await coordinator(in: hosts, excluding: failed) {
            let snapshot: ActiveTasksLiveActivitySnapshot
            do {
                snapshot = try await coordinator.read(declared)
            } catch {
                logger.notice("fleet activity read failed host=\(coordinator.id.uuidString): \(error.localizedDescription)")
                failed.insert(coordinator.id)
                coordinatorID = nil
                continue
            }
            guard activity == nil, !isRetired, scene != .background else { return }
            if snapshot.content.isEmpty {
                if snapshot.content.isCertifiedEmpty { awaitsEmpty = false }
                return
            }
            guard !awaitsEmpty, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            request(snapshot, coordinator: coordinator.id)
            return
        }
    }

    private func maintain(_ activity: Activity<Attributes>, hosts: [Host], declared: [UUID]) async {
        guard let coordinatorID = activity.attributes.coordinatorID, declared.contains(coordinatorID) else {
            logger.notice("ending fleet activity whose coordinator is no longer configured")
            await end(activity)
            schedule()
            return
        }
        register(hosts: hosts, declared: declared)
        guard scene == .active, let coordinator = hosts.first(where: { $0.id == coordinatorID }) else { return }
        do {
            _ = try await coordinator.read(declared)
        } catch {
            guard self.activity?.id == activity.id, scene == .active,
                  let replacement = await self.coordinator(in: hosts, excluding: [coordinatorID]) else { return }
            logger.notice("fleet coordinator \(coordinatorID.uuidString) unavailable; moving to \(replacement.id.uuidString)")
            await end(activity)
            self.coordinatorID = replacement.id
            schedule()
        }
    }

    private func coordinator(in hosts: [Host], excluding failed: Set<UUID>) async -> Host? {
        if let coordinatorID, !failed.contains(coordinatorID), let current = hosts.first(where: { $0.id == coordinatorID }) {
            return current
        }
        let capable = await withTaskGroup(of: UUID?.self) { group in
            for host in hosts where !failed.contains(host.id) {
                group.addTask { await host.isCoordinatorCapable() ? host.id : nil }
            }
            var capable: Set<UUID> = []
            for await case let id? in group { capable.insert(id) }
            return capable
        }
        let chosen = FleetLiveActivityPlan.coordinator(capable: hosts.map(\.id).filter(capable.contains), preferred: preferred())
        coordinatorID = chosen
        return chosen.flatMap { id in hosts.first { $0.id == id } }
    }

    private func request(_ snapshot: ActiveTasksLiveActivitySnapshot, coordinator: UUID) {
        let content = snapshot.content
        let attributes = Attributes(startedAt: .now, coordinatorID: coordinator)
        let state = Attributes.ContentState(
            activeTaskCount: content.activeTaskCount,
            attention: content.attention,
            attentionCount: content.attentionCount,
            unavailableHostIDs: content.unavailableHostIDs,
            updatedAtUnixSeconds: snapshot.updatedAtUnixSeconds
        )
        do {
            let activity = try Activity<Attributes>.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: .now.addingTimeInterval(300), relevanceScore: snapshot.relevanceScore),
                pushType: .token
            )
            logger.notice("started fleet activity id=\(activity.id) coordinator=\(coordinator.uuidString) count=\(state.activeTaskCount)")
            adopt(activity)
        } catch {
            logger.error("Failed to start fleet activity: \(String(describing: error))")
        }
    }

    private func restoreIfNeeded() async {
        guard !hasRestored else { return }
        hasRestored = true
        let activities = Activity<Attributes>.activities
        let restoration = FleetLiveActivityPlan.restore(
            activities.map {
                .init(id: $0.id, coordinatorID: $0.attributes.coordinatorID,
                      isLive: [.active, .stale].contains($0.activityState))
            },
            configured: Set(configured())
        )
        for activity in activities where restoration.ended.contains(activity.id) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        if !restoration.ended.isEmpty {
            logger.notice("retired \(restoration.ended.count) earlier active-tasks activities")
        }
        if let adopted = activities.first(where: { $0.id == restoration.adopted }) {
            coordinatorID = adopted.attributes.coordinatorID
            adopt(adopted)
        }
    }

    private func adopt(_ activity: Activity<Attributes>) {
        self.activity = activity
        token = nil
        for observer in observers { observer.cancel() }
        observers = [
            Task { [weak self] in
                for await data in activity.pushTokenUpdates {
                    guard !Task.isCancelled else { return }
                    self?.tokenChanged(data.map { String(format: "%02x", $0) }.joined(), activityID: activity.id)
                }
            },
            Task { [weak self] in
                for await _ in activity.activityStateUpdates {
                    guard !Task.isCancelled else { return }
                    self?.schedule()
                }
            },
        ]
    }

    private func tokenChanged(_ token: String, activityID: String) {
        guard activity?.id == activityID, !token.isEmpty, token != self.token else { return }
        self.token = token
        register(hosts: hosts(), declared: configured())
    }

    private func register(hosts: [Host], declared: [UUID]) {
        let coordinatorID = activity?.attributes.coordinatorID
        let registration = token.map {
            DeviceRegistrationRequest.FleetActivity(token: $0, hosts: declared.map(\.uuidString))
        }
        for host in hosts {
            host.register(host.id == coordinatorID ? registration : nil)
        }
    }

    private func drop(_ activity: Activity<Attributes>) {
        guard self.activity?.id == activity.id else { return }
        self.activity = nil
        token = nil
        for observer in observers { observer.cancel() }
        observers.removeAll()
        register(hosts: hosts(), declared: configured())
    }

    private func end(_ activity: Activity<Attributes>) async {
        drop(activity)
        await activity.end(nil, dismissalPolicy: .immediate)
    }
}
