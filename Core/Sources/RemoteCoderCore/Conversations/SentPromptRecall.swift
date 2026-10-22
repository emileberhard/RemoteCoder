import Foundation

enum SentPromptRecall {
    static func lastPrompt(in items: [ChatStreamItem]) -> ComposerDocumentContent? {
        for item in items.reversed() {
            switch item {
            case .historyEdge:
                return nil
            case .message(let message) where message.role == .user && message.questionReplies == nil:
                if let inline = message.inlineContent { return inline.document }
                let pasted = message.attachments.compactMap { attachment -> String? in
                    if case .text(let text) = attachment.content { return text }
                    return nil
                }
                let text = ([message.text] + pasted).filter { !$0.isEmpty }.joined(separator: "\n\n")
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      message.text != ChatMessage.imageAttachmentText,
                      message.text != ChatMessage.fileAttachmentText else { return nil }
                return .init(runs: [.text(text)])
            default:
                continue
            }
        }
        return nil
    }
}
