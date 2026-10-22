import Foundation
import SpeechKit
import Synchronization

enum GatewaySpeechProvider: String, Sendable {
    case openAI = "openai"
    case elevenLabs = "elevenlabs"
    case gemini
    case assemblyAI = "assemblyai"
    case azure

    var name: String {
        switch self {
        case .openAI: "OpenAI"
        case .elevenLabs: "ElevenLabs"
        case .gemini: "Gemini"
        case .assemblyAI: "AssemblyAI"
        case .azure: "Azure Speech"
        }
    }
}

struct GatewaySpeechFailure: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

struct GatewaySpeechAccess: Sendable {
    static let maximumRelayedAudioByteCount = 60_000_000

    let host: GatewayHostConfiguration
    private let transports: RouteTransports

    init(host: GatewayHostConfiguration, routes: GatewayRoutes) {
        self.host = host
        transports = RouteTransports(routes: routes)
    }

    func access(to provider: GatewaySpeechProvider) async throws -> SpeechProviderAccess {
        let route = await transports.routes.preferredRoute()
        guard let base = host.gatewayHTTPBaseURL().flatMap(route.url(replacingAddressOf:)) else {
            throw GatewaySpeechFailure(message: "\(host.errorLabel) has an invalid gateway address.")
        }
        return .relay(try SpeechRelay(
            baseURL: base.appending(path: "speech").appending(path: provider.rawValue),
            bearerToken: host.authToken,
            transport: transports.transport(for: route)
        ))
    }

    func explain(_ error: any Error, provider: GatewaySpeechProvider) -> any Error {
        guard case .relayRejected(let kind) = Self.transportCause(of: error) as? SpeechKitError else { return error }
        let detail = GatewaySpeechRejection(rawValue: kind)?.detail(provider: provider)
            ?? "the gateway refused the request (\(kind))."
        return GatewaySpeechFailure(message: "\(provider.name) through \(host.errorLabel) failed: \(detail)")
    }

    private static func transportCause(of error: any Error) -> any Error {
        switch error as? RealtimeDictationError {
        case .connectionFailed(let cause), .streamFailed(let cause): cause
        default: error
        }
    }

    private final class RouteTransports: Sendable {
        let routes: GatewayRoutes
        private let latest = Mutex<(route: GatewayRoute, transport: SpeechRelayTransport)?>(nil)

        init(routes: GatewayRoutes) {
            self.routes = routes
        }

        func transport(for route: GatewayRoute) -> SpeechRelayTransport? {
            guard route != .configured else { return nil }
            return latest.withLock { latest in
                if let latest, latest.route == route { return latest.transport }
                let transport = SpeechRelayTransport(
                    configure: { route.configure($0) },
                    acceptsServerTrust: { [routes] in routes.acceptsServerTrust($0) }
                )
                latest = (route, transport)
                return transport
            }
        }
    }
}

private enum GatewaySpeechRejection: String {
    case unauthorized
    case unavailable
    case authenticationUnavailable
    case notPermitted
    case operationNotAllowed
    case capacity
    case draining
    case credentialsUnavailable
    case requestTooLarge
    case clientStalled
    case upstreamUnreachable
    case upstreamRejected
    case upstreamFailed

    func detail(provider: GatewaySpeechProvider) -> String {
        switch self {
        case .unavailable: "speech is not configured on this gateway."
        case .unauthorized: "the gateway rejected this device's credential."
        case .authenticationUnavailable: "the gateway cannot read its installation credentials."
        case .notPermitted: "this device is not in the gateway's RC_CODEX_GATEWAY_SPEECH_CLIENTS."
        case .operationNotAllowed: "the gateway does not relay this request; update the gateway."
        case .capacity: "the gateway is already relaying its maximum number of speech sessions."
        case .draining: "the gateway is restarting."
        case .credentialsUnavailable: "the gateway cannot read its llm-router key."
        case .requestTooLarge: "the recording exceeds the gateway's 64 MiB limit."
        case .clientStalled: "the recording stopped reaching the gateway for 30 seconds."
        case .upstreamUnreachable: "the gateway could not reach \(provider.name)."
        case .upstreamRejected: "llm-router or \(provider.name) rejected the gateway's connection."
        case .upstreamFailed: "the gateway's connection to \(provider.name) failed."
        }
    }
}
