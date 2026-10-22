import Foundation

/// Connection addresses are not interchangeable physical identities. Exact
/// duplicates are ambiguous; physical identities come from the gateway.
enum AutomationHostResolver {
    static func resolve(_ name: String, hosts: [GatewayHostConfiguration], reportedHostnames: [UUID: String]) -> GatewayHostConfiguration? {
        guard name != "auto" else { return nil }
        let exact = hosts.filter { $0.hostname == name }
        if !exact.isEmpty { return exact.count == 1 ? exact.first : nil }
        let physical = hosts.filter { reportedHostnames[$0.id] == name }
        return physical.count == 1 ? physical.first : nil
    }
}
