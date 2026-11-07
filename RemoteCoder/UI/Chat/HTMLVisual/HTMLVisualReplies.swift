import Foundation
import Observation
import SwiftUI

@Observable @MainActor
final class HTMLVisualReplies {
    private(set) var index = HTMLVisualReplyIndex.unknown
    @ObservationIgnored private var threadID: String?
    @ObservationIgnored private let send: @MainActor (HTMLVisualReply, String) async throws -> Void

    init(send: @escaping @MainActor (HTMLVisualReply, String) async throws -> Void) {
        self.send = send
    }

    func update(_ index: HTMLVisualReplyIndex, threadID: String?) {
        self.threadID = threadID
        if self.index != index { self.index = index }
    }

    func sent(for key: HTMLVisualReplyKey?) -> [String]? {
        key.flatMap { index.sent(for: $0) }
    }

    func channel(for key: HTMLVisualReplyKey?) -> HTMLVisualReplyChannel {
        guard let key, let threadID else { return .detached(sent: nil) }
        return HTMLVisualReplyChannel(
            sent: { [weak self] in
                guard let self, self.threadID == threadID else { return nil }
                return index.sent(for: key)
            },
            send: { [weak self] text in
                guard let self, self.threadID == threadID else { throw HTMLVisualReplyChannel.Unavailable() }
                guard let reply = HTMLVisualReply(key: key, text: text) else { throw HTMLVisualReplyError.invalidText }
                try await send(reply, threadID)
            })
    }
}

enum HTMLVisualReplyError: LocalizedError {
    case otherConversation, readOnly, invalidText

    var errorDescription: String? {
        switch self {
        case .otherConversation: "This visual belongs to another conversation."
        case .readOnly: "This conversation can't receive messages."
        case .invalidText: "A visual can send only nonblank text up to 16 KB."
        }
    }
}

extension EnvironmentValues {
    @Entry var htmlVisualReplies: HTMLVisualReplies?
    @Entry var htmlVisualTurnID: String?
}
