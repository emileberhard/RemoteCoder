#if os(macOS)
import AppKit
import SwiftUI

struct QuickEntryView: View {
    let session: QuickEntrySession
    let close: () -> Void
    let openInWindow: (ConversationAddress) -> Void

    var body: some View {
        content
            .padding(14)
            .frame(width: 620)
            .appGlass(.standard, in: .rect(cornerRadius: 24, style: .continuous))
            .onExitCommand(perform: close)
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .composing, .sending:
            if let screen = session.screen {
                QuickEntryComposer(session: session, screen: screen)
            } else {
                Text("Add a gateway in RemoteCoder to send prompts.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .delivered(let delivery):
            QuickEntryConfirmation(delivery: delivery, openInWindow: openInWindow)
        }
    }
}

private struct QuickEntryComposer: View {
    let session: QuickEntrySession
    @Bindable var screen: ChatScreenModel
    @FocusState private var isPromptFocused: Bool
    @State private var editingAttachment: EditingTextAttachment?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !screen.composerAttachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(screen.composerAttachments) { attachment in
                            if let content = ComposerMediaTile.Content(attachment.content) {
                                ComposerMediaTile(attachment: content,
                                    stagedCopy: attachment.file.flatMap(screen.target.fileImports.stagedCopy),
                                    uploadState: screen.fileUploads[attachment.id],
                                    removeAction: { screen.removeAttachment(attachment) }, retryAction: { screen.retryUpload(attachment.id) })
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .environment(\.chatImageSource, ChatImageSource(screen: screen))
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let document = screen.composerDocument {
                    ComposerTextInput(document: document, prompt: prompt, focus: $isPromptFocused,
                                      actions: inputActions, maximumLines: 8)
                        .id(document.id)
                }
                sendButton
            }
            if let notice {
                Text(notice)
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            QuickEntryDestinationBar(session: session, screen: screen)
            Divider()
            QuickEntryDestinationList(session: session, screen: screen)
        }
        .defaultFocus($isPromptFocused, true)
        .sheet(item: $editingAttachment) { editing in
            PastedTextEditor(text: editing.text) { text in
                editing.screen.updatePastedText(text, attachmentID: editing.attachmentID, in: editing.draft)
            }
        }
    }

    private var prompt: String {
        if screen.canSteerCurrentConversation { return "Guide the next steps…" }
        return screen.currentAgentProvider == .claude ? "Message Claude…" : "Message Codex…"
    }

    private var notice: String? {
        screen.alert?.message ?? screen.currentConversationDispatchBlock?.label ?? screen.newChatModelUnavailableReason
    }

    @ViewBuilder
    private var sendButton: some View {
        if session.isSending {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Sending")
        } else {
            Button("Send", systemImage: "arrow.up", action: send)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .disabled(!screen.composerSendState.canSend)
                .help(screen.composerSendState == .steer ? "Send guidance to the running turn" : "Send the prompt")
                .accessibilityLabel(screen.composerSendState.accessibilityLabel)
        }
    }

    private var inputActions: ComposerInputActions {
        ComposerInputActions(send: send,
            lastSentPrompt: { SentPromptRecall.lastPrompt(in: screen.streamItems) },
            stop: {
                guard case .ready(let turn) = screen.composerStopState else { return false }
                screen.stopTurn(turn)
                return true
            },
            attach: { _ = screen.attachPastedContent($0) },
            openPastedText: { id in
                guard let draft = screen.currentDraft,
                      let entry = screen.composerDocument?.content.pasted.first(where: { $0.id == id }) else { return }
                editingAttachment = EditingTextAttachment(attachmentID: id, text: entry.text, draft: draft, screen: screen)
            },
            dropTargetChanged: { _ in })
    }

    private func send() {
        Task { await session.send() }
    }
}

private struct QuickEntryDestinationBar: View {
    let session: QuickEntrySession
    let screen: ChatScreenModel

    private var isNewChat: Bool { screen.activeSessionID == nil }

    var body: some View {
        HStack(spacing: 8) {
            if session.hasMultipleHosts {
                Picker("Host", selection: Binding(get: { screen.hostID }, set: { session.selectHost($0) })) {
                    ForEach(session.hosts) { host in
                        Text(host.displayName).tag(host.id)
                    }
                }
                .fixedSize()
                .help("Choose the host for a new chat")
                .disabled(!isNewChat)
            }
            Picker("Folder", selection: Binding(get: { screen.workingDirectory ?? "" }, set: { session.selectFolder($0) })) {
                if screen.workingDirectory == nil {
                    Text("No Folder").tag("")
                }
                ForEach(folders, id: \.self) { path in
                    Text(WorkingDirectoryPathFormatter.displayPath(path, remoteHomePath: screen.target.remoteHomePath)).tag(path)
                }
            }
            .fixedSize()
            .help("Choose the folder for a new chat")
            .disabled(!isNewChat)
            modelPicker
            Spacer(minLength: 0)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
    }

    @ViewBuilder
    private var modelPicker: some View {
        let options = session.modelOptions(for: screen)
        if screen.isLoadingConversationSettings {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Loading conversation settings")
        } else if !options.isEmpty {
            Picker("Model", selection: Binding(get: { screen.selectedModel }, set: { if let option = $0 { session.selectModel(option) } })) {
                ForEach(options) { option in
                    Text(option.displayName).tag(Optional(option))
                }
            }
            .fixedSize()
            .help("Choose the model")
        }
    }

    private var folders: [String] {
        var seen = Set<String>()
        let candidates = [screen.workingDirectory].compactMap(\.self) + screen.target.directories.favorites
            + [screen.target.remoteHomePath].compactMap(\.self)
        return candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

private struct QuickEntryDestinationList: View {
    let session: QuickEntrySession
    let screen: ChatScreenModel

    var body: some View {
        VStack(spacing: 2) {
            QuickEntryDestinationRow(
                title: "New Chat", detail: nil, symbol: "square.and.pencil", needsInput: false,
                isSelected: screen.activeSessionID == nil, help: "Send as a new chat", action: session.startNewChat)
            ForEach(session.recents) { row in
                QuickEntryDestinationRow(
                    title: row.title, detail: detail(of: row), symbol: row.needsInput ? "hand.raised.fill" : "bubble.left",
                    needsInput: row.needsInput, isSelected: session.isTargeting(row),
                    help: "Send to this conversation", action: { session.target(row) })
            }
        }
    }

    private func detail(of row: ConversationSidebarRow) -> String {
        [row.workingDirectory, row.showsHostLabel ? row.hostName : nil,
         row.sidebarDate.formatted(.relative(presentation: .named))]
            .compactMap(\.self).joined(separator: " · ")
    }
}

private struct QuickEntryDestinationRow: View {
    let title: String
    let detail: String?
    let symbol: String
    let needsInput: Bool
    let isSelected: Bool
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(needsInput ? Color.orange : Color.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    if let detail {
                        Text(detail)
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(.rect)
            .background(isHovered ? Color.primary.opacity(0.08) : Color.clear, in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityValue(needsInput ? "Needs input" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct QuickEntryConfirmation: View {
    let delivery: QuickEntrySession.Delivery
    let openInWindow: (ConversationAddress) -> Void

    var body: some View {
        let address = delivery.address
        HStack(spacing: 12) {
            if address != nil {
                Image(systemName: "checkmark.circle.fill")
                    .scaledFont(.title2)
                    .foregroundStyle(.green)
            } else if delivery.isStarting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .scaledFont(.title2)
                    .foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(address != nil ? "Sent" : (delivery.isStarting ? "Starting…" : "The chat didn't start"))
                    .scaledFont(.headline)
                Text(delivery.destination)
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Open in Window") {
                if let address { openInWindow(address) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(address == nil)
        }
    }
}
#endif
