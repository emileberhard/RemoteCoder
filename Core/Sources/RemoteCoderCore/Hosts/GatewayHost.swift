import Foundation

enum GatewayTransport: String, Codable, CaseIterable, Sendable {
    case tls
    case trustedNetwork
    var label: String { self == .tls ? "HTTPS / WSS" : "Trusted private network" }
}

struct GatewayHostConfiguration: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var hostname: String
    var port: Int
    var authToken: String
    var incomingCallHostID: UUID?
    var gatewayID: UUID?
    var legacyIDs: [UUID] = []
    var transport: GatewayTransport

    init(
        id: UUID,
        name: String,
        hostname: String,
        port: Int,
        authToken: String,
        transport: GatewayTransport = .tls
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.authToken = authToken
        self.transport = transport
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, hostname, port, authToken, incomingCallHostID, transport, gatewayID, legacyIDs
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        hostname = try values.decode(String.self, forKey: .hostname)
        port = try values.decode(Int.self, forKey: .port)
        authToken = try values.decode(String.self, forKey: .authToken)
        incomingCallHostID = try values.decodeIfPresent(UUID.self, forKey: .incomingCallHostID)
        gatewayID = try values.decodeIfPresent(UUID.self, forKey: .gatewayID)
        legacyIDs = try values.decodeIfPresent([UUID].self, forKey: .legacyIDs) ?? []
        // Legacy configurations used HTTP; preserve their established transport.
        transport = try values.decodeIfPresent(GatewayTransport.self, forKey: .transport) ?? .trustedNetwork
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return connectionSummary }
        return trimmed
    }

    var connectionSummary: String {
        "\(hostname):\(port)"
    }

    var isValid: Bool { gatewayWebSocketURL() != nil && !authToken.isEmpty }

    /// Names the host in connection errors.
    ///
    /// A dead gateway and a wrong active host produce the same transport
    /// failure, so the address is what tells the two apart.
    var errorLabel: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return connectionSummary }
        return "\(trimmed) (\(connectionSummary))"
    }

    /// A display-name edit must not retire a live connection, so ownership
    /// changes are decided by the endpoint and credential only.
    func hasSameConnection(as other: GatewayHostConfiguration) -> Bool {
        hasSameEndpoint(as: other) && authToken == other.authToken
    }

    func hasSameEndpoint(as other: GatewayHostConfiguration) -> Bool {
        hostname == other.hostname && port == other.port && transport == other.transport
    }

    var usesInstallationCredential: Bool { authToken.hasPrefix("rc1.") }

    var enrollmentCredential: String? {
        usesInstallationCredential || authToken.isEmpty ? nil : authToken
    }

    func gatewayWebSocketURL() -> URL? {
        endpoint(scheme: transport == .tls ? "wss" : "ws", path: "/ws")
    }

    func gatewayHTTPBaseURL() -> URL? {
        endpoint(scheme: transport == .tls ? "https" : "http", path: "")
    }
    private func endpoint(scheme: String, path: String) -> URL? {
        guard (1...65535).contains(port), !hostname.isEmpty,
              hostname.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !hostname.contains("/"), !hostname.contains("@"),
              !hostname.contains("?"), !hostname.contains("#") else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = hostname
        components.port = port
        components.path = path
        return components.url
    }

    static func builtInDefaults(from configuration: LocalConfiguration) -> [GatewayHostConfiguration] {
        guard let primaryID = UUID(uuidString: "9F8C0E05-5F3B-4A0F-B55D-FAE0E2D70352") else {
            preconditionFailure("Invalid built-in gateway host identifiers")
        }
        let port = configuration.codexGatewayPort ?? 8787
        let authToken = configuration.codexGatewayAuthToken ?? ""
        var hosts: [GatewayHostConfiguration] = []

        if let macMiniHostname = configuration.macMiniHostname, !macMiniHostname.isEmpty {
            hosts.append(
                GatewayHostConfiguration(
                    id: primaryID,
                    name: "Primary Gateway",
                    hostname: macMiniHostname,
                    port: port,
                    authToken: authToken,
                    transport: .trustedNetwork
                )
            )
        }

        if let macBook = builtInMacBook(from: configuration) { hosts.append(macBook) }

        if hosts.isEmpty {
            hosts.append(
                GatewayHostConfiguration(
                    id: primaryID,
                    name: "Local Gateway",
                    hostname: "127.0.0.1",
                    port: port,
                    authToken: authToken,
                    transport: .trustedNetwork
                )
            )
        }

        return hosts
    }

    enum MacBookSeedError: LocalizedError, Equatable {
        case unavailable, wrongHost, invalid
        var errorDescription: String? {
            switch self {
            case .unavailable: "The bundled configuration has no MacBook gateway seed."
            case .wrongHost: "A benchmark can use only the configured MacBook gateway seed."
            case .invalid: "The configured MacBook gateway seed is invalid."
            }
        }
    }

    static func macBookSeed(matching requestedID: UUID, from configuration: LocalConfiguration) throws -> GatewayHostConfiguration {
        guard let seed = builtInMacBook(from: configuration) else { throw MacBookSeedError.unavailable }
        guard seed.id == requestedID else { throw MacBookSeedError.wrongHost }
        guard seed.isValid else { throw MacBookSeedError.invalid }
        return seed
    }

    private static func builtInMacBook(from configuration: LocalConfiguration) -> GatewayHostConfiguration? {
        guard let hostname = configuration.macBookHostname, !hostname.isEmpty else { return nil }
        guard let id = UUID(uuidString: "6A71F6AF-4C5B-47F8-8A59-CFE189450A44") else {
            preconditionFailure("Invalid built-in MacBook gateway identifier")
        }
        return GatewayHostConfiguration(id: id, name: "Secondary Gateway", hostname: hostname,
            port: configuration.codexGatewayPort ?? 8787, authToken: configuration.codexGatewayAuthToken ?? "",
            transport: .trustedNetwork)
    }
}

/// A host configuration proven to produce usable gateway endpoints, so
/// consumers never re-check optionality that `HostStore` already excluded.
struct ValidatedGatewayHost: Identifiable, Equatable, Sendable {
    let configuration: GatewayHostConfiguration
    let webSocketURL: URL
    let httpBaseURL: URL

    init?(_ configuration: GatewayHostConfiguration) {
        guard let webSocketURL = configuration.gatewayWebSocketURL(),
              let httpBaseURL = configuration.gatewayHTTPBaseURL(),
              !configuration.authToken.isEmpty else { return nil }
        self.configuration = configuration
        self.webSocketURL = webSocketURL
        self.httpBaseURL = httpBaseURL
    }

    var id: UUID { configuration.id }
    var name: String { configuration.name }
    var hostname: String { configuration.hostname }
    var port: Int { configuration.port }
    var authToken: String { configuration.authToken }
    var transport: GatewayTransport { configuration.transport }
    var incomingCallHostID: UUID? { configuration.incomingCallHostID }
    var displayName: String { configuration.displayName }
    var connectionSummary: String { configuration.connectionSummary }
    var errorLabel: String { configuration.errorLabel }

    func hasSameConnection(as other: GatewayHostConfiguration) -> Bool {
        configuration.hasSameConnection(as: other)
    }
}
