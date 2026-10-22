import SwiftUI

struct ComposerSendControl: View {
    let screen: ChatScreenModel
    let send: () -> Void
    let queue: () -> Void

    var body: some View {
        let input = screen.composerControlInput
        let command = ComposerSlashCommand.parse(input)
        let state = screen.composerSendState(input: input, command: command)
        let label = accessibilityLabel(input: input, command: command, state: state)
        ComposerSendButton(state: state, action: send,
                           queue: state == .steer && screen.currentAgentProvider == .codex ? queue : nil)
            .accessibilityLabel(label)
            .tooltip(LocalizedStringKey(label))
    }

    private func accessibilityLabel(input: String, command: ComposerSlashCommand.Input, state: ComposerSendState) -> String {
        if screen.compaction?.blocksSending == true { return "Wait for compaction to finish or refresh its status" }
        switch command {
        case .command(let command): return screen.compactionUnavailableReason ?? command.title
        case .incomplete: return "Choose a command before sending"
        case .unsupported(let name): return "Unknown command \(name)"
        case .unexpectedArguments(let command): return "Use \(command.invocation) on its own"
        case .message: break
        }
        if screen.isStagingFiles { return "Wait for attachments to finish preparing" }
        if screen.hasUnfinishedFileUploads { return "Wait for files to finish uploading" }
        if let block = screen.currentConversationDispatchBlock { return block.label }
        if !screen.areConversationSettingsReady { return "Wait for conversation settings to load" }
        if screen.selectedModel == nil { return screen.newChatModelUnavailableReason ?? "Choose a model before sending" }
        if state == .idle && input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Add a message or attachment before sending"
        }
        return state.accessibilityLabel
    }
}

struct ComposerSlashCommandArea: View {
    let screen: ChatScreenModel
    let focus: ComposerFocus

    var body: some View {
        let input = screen.composerControlInput
        let command = ComposerSlashCommand.parse(input)
        let suggestions = ComposerSlashCommand.suggestions(for: input)
        VStack(alignment: .leading, spacing: 0) {
            if let error = screen.slashCommandError(for: command) {
                Text(error)
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
            }
            if !suggestions.isEmpty {
                ComposerCommandSuggestions(commands: suggestions, unavailableReason: screen.compactionUnavailableReason) { command in
                    screen.chooseSlashCommand(command)
                    focus.wrappedValue = true
                }
                .composerControlHitRegion()
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }
        }
    }
}
