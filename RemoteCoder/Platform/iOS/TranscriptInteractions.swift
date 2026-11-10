import SwiftUI

struct ChatBubbleMenu: View {
    let message: ChatMessage
    let rendered: RenderedMessage?
    let onFork: ((ChatMessage) -> Void)?
    let onEditAsFork: ((ChatMessage) -> Void)?
    let onCountChanges: ((ChatMessage) -> Void)?
    let deliveryActions: MessageDeliveryActions?
    let onSelectText: ((String) -> Void)?

    var body: some View {
        if let deliveryActions {
            if message.delivery == .queued, let sendNow = deliveryActions.sendNow {
                Button {
                    sendNow(message)
                } label: {
                    Label("Send Now", systemImage: "arrow.up.circle")
                }
            }
            if message.delivery == .queued, message.restorableComposerContent != nil {
                Button("Edit", systemImage: "pencil") { deliveryActions.edit(message) }
            }
            Button(role: .destructive) {
                deliveryActions.remove(message)
            } label: {
                Label(message.delivery == .queued ? "Remove from Queue" : "Remove", systemImage: "trash")
            }
        }

        Button {
            HapticService.shared.copy(rendered?.plainText ?? message.inlineContent?.plainText ?? message.text)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }

        Button("Copy as Markdown", systemImage: "doc.text") {
            HapticService.shared.copy(message.markdownSource(rendered: rendered))
        }
        if let onSelectText {
            Button("Select Text", systemImage: "text.cursor") {
                onSelectText(rendered?.plainText ?? message.inlineContent?.plainText ?? message.text)
            }
        }

        ShareLink(item: message.markdownSource(rendered: rendered)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }

        if onFork != nil || onEditAsFork != nil || onCountChanges != nil {
            Section {
                if let onFork {
                    Button("Fork from Here", systemImage: "arrow.triangle.branch") { onFork(message) }
                }
                if let onEditAsFork {
                    Button("Edit as Fork", systemImage: "square.and.pencil") { onEditAsFork(message) }
                }
                if let onCountChanges {
                    Button("Count Changes from Here", systemImage: ChangesView.sinceSymbol) { onCountChanges(message) }
                }
            }
        }
    }
}

struct FileAttachmentMenu: View {
    let file: UploadedFile

    var body: some View {
        Button {
            HapticService.shared.copy(file.path)
        } label: {
            Label("Copy Path", systemImage: "doc.on.doc")
        }
    }
}

extension View {
    func codeCopyButtonStyle() -> some View { buttonStyle(ResponsiveButtonStyle(feedback: nil)) }

    func transcriptHorizontalScrollIndicators() -> some View { scrollIndicators(.hidden) }

    func codeBlockActions(code: String, language: String?) -> some View { self }

    func codeBlockDragSource(_ code: String) -> some View { self }

    func transcriptTextSelection() -> some View { self }
}
