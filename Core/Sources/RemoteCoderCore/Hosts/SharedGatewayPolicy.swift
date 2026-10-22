import Foundation

struct SharedGatewayPolicy: Sendable {
    let isIsolated: Bool
    let forcesRelay: Bool

    static let production = SharedGatewayPolicy(
        isIsolated: false, forcesRelay: ProcessInfo.processInfo.environment["RC_GATEWAY_ROUTE"] == "relay")
    static let isolated = SharedGatewayPolicy(isIsolated: true, forcesRelay: false)

    var registersDevice: Bool { !isIsolated }
    var syncsPreferences: Bool { !isIsolated }
    var usesLearnedRoutes: Bool { !isIsolated }
}
