import Foundation

enum SentPromptRecall {
    static func lastPrompt(in items: [ChatStreamItem]) -> ComposerDocumentContent? {
        for item in items.reversed() {
            switch item {
            case .historyEdge:
                return nil
            case .message(let message) where message.role == .user && message.questionReplies == nil:
                return message.composerContent
            default:
                continue
            }
        }
        return nil
    }
}

extension ChatMessage {
    var composerContent: ComposerDocumentContent? {
        guard role == .user, questionReplies == nil else { return nil }
        if let inlineContent { return inlineContent.document }
        let pasted = attachments.compactMap { attachment -> String? in
            if case .text(let text) = attachment.content { return text }
            return nil
        }
        let text = ([text] + pasted).filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              self.text != Self.imageAttachmentText,
              self.text != Self.fileAttachmentText else { return nil }
        return .init(runs: [.text(text)])
    }

    var restorableComposerContent: ComposerDocumentContent? {
        guard visualReplies.isEmpty, attachments.allSatisfy({ attachment in
            if case .text = attachment.content { true } else { false }
        }) else { return nil }
        return composerContent
    }
}
