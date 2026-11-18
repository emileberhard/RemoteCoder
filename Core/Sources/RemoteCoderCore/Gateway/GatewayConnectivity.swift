import Foundation

enum GatewayConnectivity: Sendable, Equatable {
    case connected(GatewayRoute.Kind)
    case restarting
    case unreachable(GatewayConnectionFailure)
    case disconnected

    var route: GatewayRoute.Kind? {
        if case .connected(let route) = self { route } else { nil }
    }
}

struct GatewayConnectionFailure: Sendable, Equatable {
    enum Cause: Sendable, Equatable {
        case noAnswer
        case credentialsRejected
        case refused
    }

    let cause: Cause
    let since: Date
}
