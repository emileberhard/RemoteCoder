import Foundation
import Observation

struct DeviceRegistrationRequest: Codable, Equatable, Sendable {
    struct Navigation: Codable, Equatable, Sendable {
        var eventBaseURL: String
        var setupReady: Bool
        var authorization: String
        var fullAccuracy: Bool
        var googleTermsAccepted: Bool

        private enum CodingKeys: String, CodingKey {
            case setupReady, authorization, fullAccuracy, googleTermsAccepted
            case eventBaseURL = "eventBaseUrl"
        }
    }

    struct Location: Codable, Equatable, Sendable {
        var token: String
        var navigation: Navigation
    }

    struct Tokens: Codable, Equatable, Sendable {
        var alert: String?
        var liveActivity: String?
        var voip: String?
        var location: Location?

        var isEmpty: Bool { alert == nil && liveActivity == nil && voip == nil && location == nil }
    }

    var deviceId: String
    var bundleId: String
    var apnsEnvironment: String
    var appHostId: String
    var tokens: Tokens
}

struct DeviceRegistrationResponse: Decodable, Equatable, Sendable {
    let hostId: UUID
}

struct DeviceLocationCredentials: Codable, Equatable, Sendable {
    var token: String
    var setupReady: Bool
    var authorization: String
    var fullAccuracy: Bool
    var googleTermsAccepted: Bool
}

struct DeviceCredentials: Equatable, Sendable {
    var deviceID: String
    var bundleID: String
    var apnsEnvironment: String
    var alertToken: String?
    var voipToken: String?
    var location: DeviceLocationCredentials?
}

protocol DeviceRegistrationTransport: Sendable {
    var connectionIdentity: UUID? { get async }
    func connectIfNeeded() async throws
    func registerDevice(_ request: DeviceRegistrationRequest) async throws -> DeviceRegistrationResponse
    func unregisterDevice(deviceID: String) async throws
}

/// One installation's registration with one host. It is the only writer of that
/// host's push destinations: tokens go up when the app is connected and change,
/// and a result counts only if the connection that carried it is still current.
@MainActor
@Observable
final class DeviceRegistration {
    enum State: Equatable {
        case unknown
        case absent
        case registered(routingID: UUID)
        case failed(String)
    }

    private enum Goal: Equatable {
        case register(DeviceRegistrationRequest)
        case unregister(deviceID: String)
    }

    private struct Settled {
        let goal: Goal
        let connection: UUID
        let state: State
    }

    private static let maximumPasses = 8

    private(set) var state = State.unknown

    var failure: String? {
        if case .failed(let message) = state { message } else { nil }
    }

    @ObservationIgnored private let appHostID: UUID
    @ObservationIgnored private let eventBaseURL: String?
    @ObservationIgnored private let transport: any DeviceRegistrationTransport
    @ObservationIgnored private var credentials: DeviceCredentials?
    @ObservationIgnored private var liveActivityToken: String?
    @ObservationIgnored private var settled: Settled?
    @ObservationIgnored private var failedGoal: Goal?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(appHostID: UUID, eventBaseURL: String?, transport: any DeviceRegistrationTransport) {
        self.appHostID = appHostID
        self.eventBaseURL = eventBaseURL
        self.transport = transport
    }

    func update(credentials: DeviceCredentials) {
        guard self.credentials != credentials else { return }
        self.credentials = credentials
        start()
    }

    func update(liveActivityToken: String?) {
        guard self.liveActivityToken != liveActivityToken else { return }
        self.liveActivityToken = liveActivityToken
        start()
    }

    func retry() {
        failedGoal = nil
        start()
    }

    func settle() async {
        retry()
        await task?.value
    }

    func reject(_ error: Error) {
        state = .failed(error.localizedDescription)
    }

    func retire() {
        task?.cancel()
        task = nil
    }

    private func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    private var goal: Goal? {
        guard let credentials else { return nil }
        var tokens = DeviceRegistrationRequest.Tokens(
            alert: credentials.alertToken, liveActivity: liveActivityToken, voip: credentials.voipToken
        )
        if let location = credentials.location, let eventBaseURL {
            tokens.location = .init(
                token: location.token,
                navigation: .init(
                    eventBaseURL: eventBaseURL, setupReady: location.setupReady,
                    authorization: location.authorization, fullAccuracy: location.fullAccuracy,
                    googleTermsAccepted: location.googleTermsAccepted
                )
            )
        }
        guard !tokens.isEmpty else { return .unregister(deviceID: credentials.deviceID) }
        return .register(.init(
            deviceId: credentials.deviceID, bundleId: credentials.bundleID,
            apnsEnvironment: credentials.apnsEnvironment, appHostId: appHostID.uuidString, tokens: tokens
        ))
    }

    private func run() async {
        var passes = 0
        while let goal, failedGoal != goal, passes < Self.maximumPasses, !Task.isCancelled {
            passes += 1
            do {
                try await transport.connectIfNeeded()
                guard let connection = await transport.connectionIdentity else {
                    throw DeviceRegistrationError.notConnected
                }
                if let settled, settled.goal == goal, settled.connection == connection {
                    state = settled.state
                    break
                }
                let outcome: State
                switch goal {
                case .register(let request):
                    let response = try await transport.registerDevice(request)
                    outcome = .registered(routingID: response.hostId)
                case .unregister(let deviceID):
                    try await transport.unregisterDevice(deviceID: deviceID)
                    outcome = .absent
                }
                guard await transport.connectionIdentity == connection else { continue }
                settled = Settled(goal: goal, connection: connection, state: outcome)
                if self.goal == goal { state = outcome }
            } catch {
                guard !Task.isCancelled else { break }
                failedGoal = goal
                state = .failed(error.localizedDescription)
            }
        }
        task = nil
    }
}

enum DeviceRegistrationError: LocalizedError {
    case notConnected

    var errorDescription: String? {
        switch self {
        case .notConnected: "The gateway connection closed before the device was registered."
        }
    }
}
