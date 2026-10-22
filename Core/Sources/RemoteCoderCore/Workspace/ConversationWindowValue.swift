import Foundation

enum ConversationWindowValue: Hashable, Codable, Sendable {
    case conversation(ConversationAddress)
    case newChat(slot: UUID)
    case unsentDraft(UnsentDraftAddress)
}
