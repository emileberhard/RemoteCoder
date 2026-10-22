import Foundation

/// Actual dispatch receipts name the conversation owner. Saved definition
/// targets are not substitutes for missing or uncertain execution identities.
struct AutomationExecutionRoute: Equatable, Sendable {
    let host: String
    let threadID: String

    init?(receipt: JSONValue?) {
        guard let fields = receipt?.objectValue,
              let host = fields["gateway_host"]?.stringValue, !host.isEmpty,
              let thread = fields["thread_id"]?.stringValue, !thread.isEmpty else { return nil }
        self.host = host; threadID = thread
    }
}
