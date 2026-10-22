import Foundation

/// Broker delivery is the only alert source. Socket lifecycle/replay updates
/// conversation state, while this owner chooses the foreground surface.
enum ForegroundNotificationPresentation {
    enum Disposition { case inApp, system, suppressed }

    struct Delivery: Sendable {
        let isConversationAlert: Bool
        let title: String
        let body: String
        let payload: TaskCompletionNotificationPayload?
        let decodingFailure: String?
    }

    struct Banner: Identifiable {
        let id = UUID()
        let delivery: Delivery
        var payload: TaskCompletionNotificationPayload? { delivery.payload }
    }

    /// Only prepared presentation state crosses onto the main actor. Unknown
    /// payload shapes retain delivered copy and no unproven navigation action.
    @concurrent
    static func prepare(payloadJSON: String?, title: String, body: String, containsPayload: Bool = false) async -> Delivery {
        var payload: TaskCompletionNotificationPayload?
        var failure: String? = containsPayload && payloadJSON == nil ? "payload" : nil
        if let payloadJSON {
            do { payload = try JSONDecoder().decode(TaskCompletionNotificationPayload.self, from: Data(payloadJSON.utf8)) }
            catch {
                let path: [any CodingKey]
                switch error {
                case DecodingError.keyNotFound(let key, let context): path = context.codingPath + [key]
                case DecodingError.typeMismatch(_, let context),
                     DecodingError.valueNotFound(_, let context),
                     DecodingError.dataCorrupted(let context): path = context.codingPath
                default: path = []
                }
                failure = path.isEmpty ? "root" : path.map(\.stringValue).joined(separator: ".")
            }
        }
        return Delivery(isConversationAlert: containsPayload || payloadJSON != nil, title: title.isEmpty ? payload?.title ?? "RemoteCoder" : title,
                        body: body.isEmpty ? payload?.messagePreview ?? "New notification" : body,
                        payload: payload, decodingFailure: failure)
    }

    static func isOpen(_ payload: TaskCompletionNotificationPayload, address: ConversationAddress?) -> Bool {
        guard let address else { return false }
        return payload.hostID == address.hostID && payload.sessionID == address.threadID
    }

    /// Bounded at 256 delivered event IDs, persisted by the workspace on receipt.
    /// Suppressed and tapped deliveries are consumed too, so selection or replay
    /// cannot turn the same event into a second banner.
    struct Ledger {
        private(set) var eventIDs: [String]
        init(eventIDs: [String] = []) {
            self.eventIDs = eventIDs.suffix(256).map { value in
                let parts = value.split(separator: "|", maxSplits: 3).map(String.init)
                guard parts.count == 4, UUID(uuidString: parts[1]) != nil, UInt64(parts[2]) != nil else { return value }
                return "\(parts[0])|default|\(parts[3])"
            }
        }

        mutating func consume(_ payload: TaskCompletionNotificationPayload) -> Bool {
            // Two unknown origins are not evidence of one delivery. Legacy
            // payloads may render, but cannot enter the cross-delivery ledger.
            guard let id = payload.presentationID else { return true }
            guard !eventIDs.contains(id) else { return false }
            eventIDs.append(id)
            if eventIDs.count > 256 { eventIDs.removeFirst(eventIDs.count - 256) }
            return true
        }
    }
}
