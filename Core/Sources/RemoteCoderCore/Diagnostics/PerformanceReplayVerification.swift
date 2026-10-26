#if RC_PERF_HARNESS || SWIFT_PACKAGE
import Foundation

enum PerformanceReplayVerification {
    struct Identity: Hashable, Sendable {
        let turn: String
        let item: String
    }

    struct Completion: Sendable {
        let identity: Identity
        let text: String
    }

    static func completions(threadID: String, events: [PerformanceReplayScenario.Event]) -> [Completion] {
        var entries: [Identity: Completion] = [:]
        for event in events {
            guard let fields = event.frame.objectValue, fields["method"] == .string("item/completed"),
                  let params = fields["params"]?.objectValue, params["threadId"] == .string(threadID),
                  let item = params["item"]?.objectValue, item["type"] == .string("agentMessage"),
                  let id = item["id"]?.stringValue, let turn = params["turnId"]?.stringValue,
                  let text = item["text"]?.stringValue else { continue }
            let identity = Identity(turn: turn, item: id)
            entries[identity] = Completion(identity: identity, text: text)
        }
        return entries.values.sorted { ($0.identity.turn, $0.identity.item) < ($1.identity.turn, $1.identity.item) }
    }

    static func checks(_ completions: [Completion], messages: [ChatMessage], window: HistoryWindow?) -> [Identity: Bool] {
        let loaded = Set(window?.turns.flatMap { turn in
            turn.entries.map { Identity(turn: $0.turnId, item: $0.item.id) }
        } ?? [])
        let retained = Dictionary(messages.compactMap { message -> (Identity, ChatMessage)? in
            guard let turn = message.canonicalTurnID, let item = message.canonicalItemID else { return nil }
            return (Identity(turn: turn, item: item), message)
        }, uniquingKeysWith: { _, latest in latest })
        return Dictionary(uniqueKeysWithValues: completions.filter {
            loaded.contains($0.identity) || retained[$0.identity] != nil
        }.map { completion in
            let message = retained[completion.identity]
            return (completion.identity, message?.text == completion.text && message?.isStreaming == false)
        })
    }
}
#endif
