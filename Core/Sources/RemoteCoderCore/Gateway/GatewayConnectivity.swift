import Foundation

enum GatewayConnectivity: Sendable, Equatable {
    case connected(GatewayRoute.Kind)
    case restarting
    case unreachable
    case disconnected

    var route: GatewayRoute.Kind? {
        if case .connected(let route) = self { route } else { nil }
    }
}
