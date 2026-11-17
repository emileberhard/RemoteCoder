import Foundation
#if canImport(RemoteCoderCore)
@testable import RemoteCoderCore
#else
@testable import RemoteCoder
#endif

enum GatewayEventFixture {
    enum Failure: Error { case invalidEvent }

    static func notification(method: String, params: JSONValue?, receivedAt: Date? = nil, sequence: UInt64? = nil,
                             receipt: GatewayWireReceipt? = nil) -> CodexGatewayNotification {
        CodexGatewayNotification(method: method, params: params, server: ServerNotification.decode(method: method, params: params),
                                 receivedAt: receivedAt, sequence: sequence, receipt: receipt)
    }

    static func route(_ method: String, params: [String: JSONValue], receivedAt: Date = Date(timeIntervalSince1970: 1)) -> RoutedGatewayEvent? {
        GatewayNotificationRouting.route(notification(method: method, params: .object(params), receivedAt: receivedAt))
    }

    static func turn(_ method: String, params: [String: JSONValue], receivedAt: Date = Date(timeIntervalSince1970: 1)) throws -> TurnScopedGatewayEvent {
        guard case .turnEvent(let event) = route(method, params: params, receivedAt: receivedAt) else {
            throw Failure.invalidEvent
        }
        return event
    }

    static func turn(_ params: JSONValue, method: String) throws -> TurnScopedGatewayEvent {
        guard let fields = params.objectValue else { throw Failure.invalidEvent }
        return try turn(method, params: fields)
    }

    static func item(_ method: String, item: CodexAppServerV2.ThreadItem, threadID: String, turnID: String,
                     ordinal: Int, startedAtMs: Int, completedAtMs: Int) throws -> TurnScopedGatewayEvent {
        let raw = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(item))
        return try turn(method, params: [
            "threadId": .string(threadID), "turnId": .string(turnID), "item": raw,
            "startedAtOrdinal": .number(Double(ordinal)), "startedAtMs": .number(Double(startedAtMs)),
            "completedAtMs": .number(Double(completedAtMs))
        ])
    }

    static func delta(_ text: String, threadID: String, turnID: String, itemID: String) throws -> TurnScopedGatewayEvent {
        try turn("item/agentMessage/delta", params: [
            "threadId": .string(threadID), "turnId": .string(turnID), "itemId": .string(itemID), "delta": .string(text)
        ])
    }
}
