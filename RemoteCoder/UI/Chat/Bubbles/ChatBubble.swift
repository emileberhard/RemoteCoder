import Observation
import SwiftUI

struct ChatBubble: View {
    @State private var menuOwner: ChatBubbleMenuOwner
    @State private var revealsSending = false
    #if os(macOS)
    @Environment(\.transcriptSurfaceActivity) private var surfaceActivity
    #endif
    let message: ChatMessage
    /// Previous presentation remains visible until its replacement is ready.
    let renderedMessages: RenderedMessageStore
    let onFork: ((ChatMessage) -> Void)?
    let queuedActions: QueuedMessageActions?
    var onSelectText: ((String) -> Void)? = nil
    var onOpenAttachment: ((MessageAttachment) -> Void)? = nil
    static let messageVerticalInset: CGFloat = 8
    private static let sendingRevealDelay: Duration = .milliseconds(500)

    init(message: ChatMessage, renderedMessages: RenderedMessageStore,
         onFork: ((ChatMessage) -> Void)?, queuedActions: QueuedMessageActions?,
         onSelectText: ((String) -> Void)? = nil, onOpenAttachment: ((MessageAttachment) -> Void)? = nil) {
        self.message = message
        self.renderedMessages = renderedMessages
        self.onFork = onFork
        self.queuedActions = queuedActions
        self.onSelectText = onSelectText
        self.onOpenAttachment = onOpenAttachment
        _menuOwner = State(initialValue: ChatBubbleMenuOwner(message: message, renderedMessages: renderedMessages,
            onFork: onFork, queuedActions: queuedActions, onSelectText: onSelectText))
    }

    var body: some View {
        let _ = PerfBuild.count("bubble.body")
        let _ = menuOwner.update(message: message, renderedMessages: renderedMessages,
            onFork: onFork, queuedActions: queuedActions, onSelectText: onSelectText)
        #if os(macOS)
        let _ = surfaceActivity?.recordBody()
        #endif
        messageView
            .transcriptPerfFeature("contextMenu") { view in
                let menu = ChatBubbleContextMenu(owner: menuOwner)
                if renderedMessages[message.id]?.containsHTMLVisual == true {
                    view.environment(\.chatBubbleMenuOwner, menuOwner)
                } else {
                    view.modifier(menu)
                }
            }
    }
}

private extension ChatBubble {
    @ViewBuilder
    var messageView: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                messageContent
                    .padding(14)
                    .themedSurface(cornerRadius: 18, fill: .userBubble)
                    .contentShape(RoundedRectangle(cornerRadius: 18))
            }
            .padding(.vertical, Self.messageVerticalInset)
            .task(id: message.delivery == .sending) {
                guard message.delivery == .sending, !revealsSending else { return }
                try? await Task.sleep(for: Self.sendingRevealDelay)
                if !Task.isCancelled { revealsSending = true }
            }
        case .codex:
            messageContent
                .padding(.vertical, Self.messageVerticalInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
    }

    var messageContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let delivery = message.delivery, delivery != .sending || revealsSending {
                DeliveryLabel(delivery: delivery)
            }
            if let replies = message.questionReplies, !replies.isEmpty {
                // A reply envelope shows each answer under the question it answers.
                ForEach(Array(replies.enumerated()), id: \.offset) { _, reply in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Answered: \(reply.question)")
                            .scaledFont(.caption2)
                            .foregroundStyle(.secondary)
                        Text(reply.answer)
                            .scaledFont(.body)
                            .foregroundStyle(.primary)
                            .transcriptTextSelection()
                    }
                    .accessibilityElement(children: .combine)
                }
            } else if message.role == .codex {
                PreparedAssistantContent(messageID: message.id, renderedMessages: renderedMessages)
                    .equatable()
            } else {
                userContent
            }

            ForEach(message.attachments) { attachment in
                if message.inlineContent == nil || !isPastedText(attachment) {
                    MessageAttachmentChip(attachment: attachment) { onOpenAttachment?(attachment) }
                }
            }
        }
    }

    @ViewBuilder
    var userContent: some View {
        if message.inlineContent != nil {
            if let inline = renderedMessages[message.id]?.inline {
                InlineMessageText(content: inline) { id in
                    if let attachment = message.attachments.first(where: { $0.id == id }) { onOpenAttachment?(attachment) }
                }
                .id(message.id)
            } else {
                Text(" ").scaledFont(.body).accessibilityHidden(true)
            }
        } else if let rendered = renderedMessages[message.id] {
            if !rendered.blocks.isEmpty {
                PreparedMessageText(rendered: rendered, reveal: .settled)
                    .scaledFont(.body)
            }
        } else if !message.text.isEmpty {
            Text(message.text)
                .scaledFont(.body)
                .foregroundStyle(.primary)
                .transcriptTextSelection()
        }
    }

    func isPastedText(_ attachment: MessageAttachment) -> Bool {
        if case .text = attachment.content { return true }
        return false
    }
}

private struct PreparedAssistantContent: View, Equatable {
    #if os(macOS)
    @Environment(\.transcriptSurfaceActivity) private var surfaceActivity
    #endif
    let messageID: UUID
    let renderedMessages: RenderedMessageStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appEnergyPolicy) private var energyPolicy
    @Environment(\.visualsVisible) private var visualsVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settledReveal = -TimeInterval.infinity
    private static let perfDisablesReveal = PerfBuild.isDisabled("reveal")

    var body: some View {
        let _ = PerfBuild.count("prepared.body")
        #if os(macOS)
        let _ = surfaceActivity?.recordBody()
        #endif
        let rendered = renderedMessages[messageID]
        let reveal = revealing(rendered)
        Group {
            if let rendered {
                if !rendered.blocks.isEmpty {
                    PreparedMessageText(rendered: rendered, reveal: reveal)
                        .scaledFont(.body)
                }
            } else {
                // A slow first render must not expose raw Markdown, even after
                // the bounded publication wait expires.
                Text(" ").scaledFont(.body).accessibilityHidden(true)
            }
        }
        .contentTransition(.identity)
        #if os(macOS)
        .environment(\.transcriptTextSelectionEnabled, rendered?.isStreaming != true)
        #endif
        .transcriptPerfFeature("geometryGroup") { $0.geometryGroup() }
        .background {
            if let end = reveal.end {
                StreamingRevealSettlement(end: end) { settledReveal = end }
            }
        }
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.messageID == rhs.messageID && lhs.renderedMessages === rhs.renderedMessages
    }

    private func revealing(_ rendered: RenderedMessage?) -> StreamingReveal {
        guard !Self.perfDisablesReveal, let reveal = rendered?.reveal, let end = reveal.end, end > settledReveal,
              energyPolicy.animatesDecorations(sceneActive: scenePhase == .active, visible: visualsVisible,
                                               reduceMotion: reduceMotion) else { return .settled }
        return reveal
    }
}

private struct PreparedMessageText: View {
    let rendered: RenderedMessage
    let reveal: StreamingReveal
    @Environment(\.htmlVisualCaptureAllowed) private var captureAllowed

    var body: some View {
        Group {
        #if os(macOS) && RC_PERF_HARNESS
        if PerfBuild.isDisabled("markdown") {
            Text(rendered.sourceText)
                .transcriptTextSelection()
        } else {
            MarkdownBlocksView(blocks: rendered.blocks, reveal: reveal)
        }
        #else
        MarkdownBlocksView(blocks: rendered.blocks, reveal: reveal)
        #endif
        }
        .environment(\.htmlVisualCaptureAllowed, captureAllowed && !rendered.isStreaming)
    }
}

extension EnvironmentValues {
    @Entry var chatBubbleMenuOwner: ChatBubbleMenuOwner?
}

@MainActor
@Observable
final class ChatBubbleMenuOwner {
    private(set) var message: ChatMessage
    @ObservationIgnored private(set) var renderedMessages: RenderedMessageStore
    @ObservationIgnored private(set) var onFork: ((ChatMessage) -> Void)?
    @ObservationIgnored private(set) var queuedActions: QueuedMessageActions?
    @ObservationIgnored private(set) var onSelectText: ((String) -> Void)?

    init(message: ChatMessage, renderedMessages: RenderedMessageStore, onFork: ((ChatMessage) -> Void)?,
         queuedActions: QueuedMessageActions?, onSelectText: ((String) -> Void)?) {
        self.message = message
        self.renderedMessages = renderedMessages
        self.onFork = onFork
        self.queuedActions = queuedActions
        self.onSelectText = onSelectText
    }

    func update(message: ChatMessage, renderedMessages: RenderedMessageStore, onFork: ((ChatMessage) -> Void)?,
                queuedActions: QueuedMessageActions?, onSelectText: ((String) -> Void)?) {
        self.message = message
        self.renderedMessages = renderedMessages
        self.onFork = onFork
        self.queuedActions = queuedActions
        self.onSelectText = onSelectText
    }
}

struct ChatBubbleContextMenu: ViewModifier {
    let owner: ChatBubbleMenuOwner

    func body(content: Content) -> some View {
        content.contextMenu {
            ChatBubbleOwnedMenu(owner: owner)
        } preview: {
            ChatBubbleOwnedPreview(owner: owner)
                .environment(\.transcriptRowPresentation, nil)
                .environment(\.chatBubbleMenuOwner, nil)
        }
    }
}

private struct ChatBubbleOwnedMenu: View {
    let owner: ChatBubbleMenuOwner

    var body: some View {
        ChatBubbleMenu(message: owner.message, rendered: owner.renderedMessages[owner.message.id], onFork: owner.onFork,
            queuedActions: owner.queuedActions, onSelectText: owner.onSelectText)
    }
}

private struct ChatBubbleOwnedPreview: View {
    let owner: ChatBubbleMenuOwner

    var body: some View {
        ChatBubbleContextPreview(messageID: owner.message.id, text: owner.message.text, inline: owner.message.inlineContent,
            renderedMessages: owner.renderedMessages)
    }
}

struct QueuedMessageActions {
    let sendNow: ((ChatMessage) -> Void)?
    let remove: (ChatMessage) -> Void
}

private struct DeliveryLabel: View {
    let delivery: ChatMessage.Delivery

    var body: some View {
        Label(title, systemImage: systemImage)
            .scaledFont(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityLabel(accessibilityLabel)
    }

    private var title: String {
        switch delivery {
        case .sending: "Sending"
        case .pendingSteer: "Steer pending"
        case .steered: "Steered"
        case .queueing: "Queueing"
        case .queued: "Queued"
        case .notSent: "Not sent"
        case .unconfirmed: "Unconfirmed"
        }
    }

    private var systemImage: String {
        switch delivery {
        case .sending: "ellipsis"
        case .pendingSteer: "clock"
        case .steered: "arrow.turn.down.right"
        case .queueing: "ellipsis"
        case .queued: "text.badge.plus"
        case .notSent: "exclamationmark.circle"
        case .unconfirmed: "questionmark.circle"
        }
    }

    private var accessibilityLabel: String {
        switch delivery {
        case .sending: "Sending this message to the agent"
        case .pendingSteer: "Waiting to steer the running turn at its next step"
        case .steered: "Sent as steering into the running turn"
        case .queueing: "Adding to the queue"
        case .queued: "Queued to run as a new turn after the current one"
        case .notSent: "This message was not sent"
        case .unconfirmed: "Delivery of this message is not confirmed"
        }
    }
}

private struct ChatBubbleContextPreview: View {
    let messageID: UUID
    let text: String
    let inline: InlineMessageContent?
    let renderedMessages: RenderedMessageStore

    var body: some View {
        Group {
            if let inline {
                Text(inline.contextPreview).lineLimit(8)
            } else if let rendered = renderedMessages[messageID] {
                if rendered.containsHTMLVisual {
                    Text(rendered.plainText).lineLimit(8)
                } else {
                    MarkdownBlocksView(blocks: Array(rendered.blocks.prefix(4)), reveal: .settled)
                }
            } else {
                Text(text).lineLimit(8)
            }
        }
            .scaledFont(.callout)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 260, maxHeight: 320, alignment: .topLeading)
            .clipped()
            .padding(12)
    }
}
