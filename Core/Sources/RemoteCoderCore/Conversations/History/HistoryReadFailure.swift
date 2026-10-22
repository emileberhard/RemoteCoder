import Foundation

nonisolated enum HistoryReadFailure: LocalizedError, Equatable, Sendable {
    case invalidated
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .invalidated: "Conversation history changed while loading. Try again."
        case .notLoaded: "Conversation history is not loaded. Try again."
        }
    }
}
