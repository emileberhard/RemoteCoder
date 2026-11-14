import Foundation
import SpeechKit

enum GatewaySpeechProvider: String, CaseIterable, Sendable {
    case elevenLabs = "elevenlabs"
    case assemblyAI = "assemblyai"
    case azure

    var name: String {
        switch self {
        case .elevenLabs: "ElevenLabs"
        case .assemblyAI: "AssemblyAI"
        case .azure: "Azure Speech"
        }
    }
}

struct GatewaySpeechFailure: LocalizedError, Equatable {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

struct GatewaySpeechAccess: Sendable {
    static let maximumAudioByteCount = 60_000_000

    let host: GatewayHostConfiguration
    let credentials: GatewayDictationCredentials

    init(host: GatewayHostConfiguration, routes: GatewayRoutes) {
        self.init(host: host, credentials: GatewayDictationCredentials(
            host: host, storage: KeychainGatewayCredentials(scope: .dictation(hostID: host.id)),
            fetch: { try await routes.dictationCredential() }
        ))
    }

    init(host: GatewayHostConfiguration, credentials: GatewayDictationCredentials) {
        self.host = host
        self.credentials = credentials
    }

    func access(to provider: GatewaySpeechProvider) async throws -> SpeechProviderAccess {
        let credential = try await credentials.current()
        return .router(try LLMRouter(origin: credential.origin, key: credential.key))
    }

    func perform<Value: Sendable>(
        _ operation: @Sendable (SpeechProviderAccess) async throws -> Value
    ) async throws -> Value {
        let credential = try await credentials.current()
        do { return try await operation(.router(LLMRouter(origin: credential.origin, key: credential.key))) }
        catch {
            guard Self.isUnauthorized(error), !Task.isCancelled else { throw error }
            let replacement = try await credentials.refresh(rejecting: credential.key)
            return try await operation(.router(LLMRouter(origin: replacement.origin, key: replacement.key)))
        }
    }

    func refreshIfUnauthorized(_ error: any Error) async throws {
        guard Self.isUnauthorized(error) else { return }
        let credential = try await credentials.current()
        _ = try await credentials.refresh(rejecting: credential.key)
    }

    func explain(_ error: any Error, provider: GatewaySpeechProvider) -> any Error {
        guard case .httpFailure(let status, _) = Self.transportCause(of: error) as? SpeechKitError else { return error }
        return GatewaySpeechFailure(status: status, message: "\(provider.name) dictation failed (HTTP \(status)).")
    }

    private static func isUnauthorized(_ error: any Error) -> Bool {
        if case .httpFailure(let status, _) = transportCause(of: error) as? SpeechKitError { return status == 401 }
        if case .webSocketHandshakeFailed(let status) = transportCause(of: error) as? SpeechKitError { return status == 401 }
        let error = transportCause(of: error) as NSError
        return error.domain == NSURLErrorDomain && error.code == NSURLErrorUserAuthenticationRequired
    }

    private static func transportCause(of error: any Error) -> any Error {
        switch error as? RealtimeDictationError {
        case .connectionFailed(let cause), .streamFailed(let cause): cause
        default: error
        }
    }
}
