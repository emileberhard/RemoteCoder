import Foundation
import Observation

enum HostRole: Sendable, Equatable {
    case unknown
    case portable
    case stationary

    init(internalBattery: Bool?) {
        switch internalBattery {
        case true?: self = .portable
        case false?: self = .stationary
        case nil: self = .unknown
        }
    }
}

struct HostAvailability: Sendable, Equatable {
    enum Reach: Sendable, Equatable {
        case connected(GatewayRoute.Kind)
        case connecting
        case restarting
        case offline
        case unreachable
        case unreachableFromHere
        case needsAttention(Fix)
    }

    enum Fix: Sendable, Equatable {
        case credentialsRejected
        case refused
    }

    static let warningGrace: TimeInterval = 5 * 60
    static let peerFreshness: TimeInterval = 2 * 60

    let reach: Reach
    let lastSeen: Date?
    let tasksRunningAtLoss: Int

    var route: GatewayRoute.Kind? {
        if case .connected(let route) = reach { route } else { nil }
    }

    var isConnected: Bool { route != nil }

    static func derive(connectivity: GatewayConnectivity, role: HostRole, lastSeen: Date?, tasksRunningAtLoss: Int,
                       peerSawAt: Date?, now: Date) -> (availability: HostAvailability, changesAt: Date?) {
        func value(_ reach: Reach) -> HostAvailability {
            HostAvailability(reach: reach, lastSeen: lastSeen, tasksRunningAtLoss: tasksRunningAtLoss)
        }
        switch connectivity {
        case .connected(let route): return (value(.connected(route)), nil)
        case .restarting: return (value(.restarting), nil)
        case .disconnected: return (value(.connecting), nil)
        case .unreachable(let failure):
            switch failure.cause {
            case .credentialsRejected: return (value(.needsAttention(.credentialsRejected)), nil)
            case .refused: return (value(.needsAttention(.refused)), nil)
            case .noAnswer: break
            }
            if let peerSawAt, peerSawAt >= failure.since, now.timeIntervalSince(peerSawAt) < peerFreshness {
                return (value(.unreachableFromHere), peerSawAt + peerFreshness)
            }
            guard role == .stationary else { return (value(.offline), nil) }
            let warnsAt = failure.since + warningGrace
            return now >= warnsAt ? (value(.unreachable), nil) : (value(.offline), warnsAt)
        }
    }
}

@Observable @MainActor
final class HostAvailabilityTracker {
    private(set) var current: HostAvailability

    @ObservationIgnored let hostID: UUID
    @ObservationIgnored var requestsPeerView: @MainActor () -> Void = {}
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private(set) var connectivity = GatewayConnectivity.disconnected
    @ObservationIgnored private var internalBattery: Bool?
    @ObservationIgnored private var lastSeen: Date?
    @ObservationIgnored private var tasksRunningAtLoss = 0
    @ObservationIgnored private var peerSawAt: Date?
    @ObservationIgnored private var peerViewRequestedAt: Date?
    @ObservationIgnored private var reevaluation: Task<Void, Never>?
    @ObservationIgnored private var isRetired = false

    init(hostID: UUID, defaults: UserDefaults, now: @escaping @MainActor () -> Date = { .now }) {
        self.hostID = hostID
        self.defaults = defaults
        self.now = now
        internalBattery = HostPreferences.internalBattery(hostID: hostID, defaults: defaults)
        lastSeen = HostPreferences.lastSeen(hostID: hostID, defaults: defaults)
        current = HostAvailability(reach: .connecting, lastSeen: lastSeen, tasksRunningAtLoss: 0)
    }

    var role: HostRole { HostRole(internalBattery: internalBattery) }

    func connectivityChanged(_ connectivity: GatewayConnectivity, runningTasks: Int) {
        guard !isRetired, connectivity != self.connectivity else { return }
        let wasConnected = self.connectivity.route != nil
        let wasUnreachable = if case .unreachable = self.connectivity { true } else { false }
        self.connectivity = connectivity
        if connectivity.route != nil {
            tasksRunningAtLoss = 0
            peerSawAt = nil
            recordLastSeen()
        } else if wasConnected {
            tasksRunningAtLoss = runningTasks
            recordLastSeen()
        }
        if case .unreachable = connectivity {
            if !wasUnreachable { requestPeerView() }
        } else {
            peerViewRequestedAt = nil
        }
        reevaluate()
    }

    func reported(internalBattery: Bool?) {
        guard !isRetired, let internalBattery, internalBattery != self.internalBattery else { return }
        self.internalBattery = internalBattery
        HostPreferences.setInternalBattery(internalBattery, hostID: hostID, defaults: defaults)
        reevaluate()
    }

    func peerSighted(at date: Date?) {
        guard !isRetired, date != peerSawAt else { return }
        peerSawAt = date
        reevaluate()
    }

    func retire() {
        isRetired = true
        reevaluation?.cancel()
        reevaluation = nil
    }

    private func requestPeerView() {
        peerViewRequestedAt = now()
        requestsPeerView()
    }

    private func recordLastSeen() {
        let seen = now()
        lastSeen = seen
        HostPreferences.setLastSeen(seen, hostID: hostID, defaults: defaults)
    }

    private func reevaluate() {
        reevaluation?.cancel()
        reevaluation = nil
        let derived = HostAvailability.derive(connectivity: connectivity, role: role, lastSeen: lastSeen,
                                              tasksRunningAtLoss: tasksRunningAtLoss, peerSawAt: peerSawAt, now: now())
        if derived.availability != current { current = derived.availability }
        let peerViewDue = peerViewRequestedAt.map { $0 + HostAvailability.peerFreshness }
        guard let next = [derived.changesAt, peerViewDue].compactMap({ $0 }).min() else { return }
        let delay = max(0, next.timeIntervalSince(now()))
        reevaluation = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(delay))) != nil, let self, !self.isRetired else { return }
            self.reevaluation = nil
            if peerViewDue.map({ self.now() >= $0 }) == true { self.requestPeerView() }
            self.reevaluate()
        }
    }
}
