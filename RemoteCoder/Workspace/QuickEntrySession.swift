import Foundation
import Observation

@MainActor
@Observable
final class QuickEntrySession {
    @MainActor
    struct Delivery {
        let screen: ChatScreenModel
        let destination: String

        var address: ConversationAddress? {
            screen.activeSessionID.map { ConversationAddress(hostID: screen.hostID, threadID: $0) }
        }

        var isStarting: Bool { address == nil && screen.isCurrentConversationBusy }
    }

    enum Phase {
        case composing, sending
        case delivered(Delivery)
    }

    let window: ChatWindowModel
    let recents: [ConversationSidebarRow]
    private(set) var phase = Phase.composing
    @ObservationIgnored private let workspace: ChatWorkspaceModel
    @ObservationIgnored private let draftNavigation = ConversationDraftNavigation()

    init(workspace: ChatWorkspaceModel, window: ChatWindowModel, recents: [ConversationSidebarRow]) {
        self.workspace = workspace
        self.window = window
        self.recents = recents
    }

    var screen: ChatScreenModel? { window.selectedScreen }

    var hosts: [ValidatedGatewayHost] { workspace.settings.hosts }

    var hasMultipleHosts: Bool { workspace.hasMultipleHosts }

    var isSending: Bool {
        if case .sending = phase { return true }
        return false
    }

    func modelOptions(for screen: ChatScreenModel) -> [ModelOption] {
        workspace.modelOptions(for: screen)
    }

    func isTargeting(_ row: ConversationSidebarRow) -> Bool {
        workspace.isShowingConversation(at: row.address, on: screen)
    }

    func destinationName(of screen: ChatScreenModel) -> String {
        if screen.activeSessionID != nil, let row = recents.first(where: { workspace.isShowingConversation(at: $0.address, on: screen) }) {
            return row.title
        }
        let folder = screen.workingDirectory.map { WorkingDirectoryPathFormatter.displayPath($0, remoteHomePath: screen.target.remoteHomePath) }
        return [folder, workspace.targetName(of: screen.target)].compactMap(\.self).joined(separator: " · ")
    }

    @discardableResult
    func target(_ row: ConversationSidebarRow) -> Task<Void, Never>? {
        carryingDraft(toHost: row.address.hostID) { [weak self] in
            guard let self else { return false }
            if let opening = workspace.selectConversation(at: row.address) {
                await withTaskCancellationHandler {
                    await opening.value
                } onCancel: { opening.cancel() }
            }
            return workspace.isShowingConversation(at: row.address, on: window.selectedScreen)
        }
    }

    func startNewChat() {
        guard case .composing = phase, isKey, let screen else { return }
        workspace.supersedePendingNavigation()
        guard screen.activeSessionID != nil else {
            cancelNavigation()
            return
        }
        carryingDraft(toHost: screen.hostID) { [weak self] in
            self?.workspace.startNewConversation(provider: screen.currentAgentProvider, preferredHostID: screen.hostID) != nil
        }
    }

    func selectHost(_ hostID: UUID) {
        carryingDraft(toHost: hostID) { [weak self] in
            guard let self else { return false }
            workspace.select(hostID: hostID)
            return window.selectedScreen?.hostID == hostID
        }
    }

    func selectFolder(_ path: String) {
        screen?.selectWorkingDirectory(path)
    }

    func selectModel(_ option: ModelOption) {
        guard isKey else { return }
        workspace.selectModel(option)
    }

    func send() async {
        guard case .composing = phase, isKey, let screen, screen.composerSendState.canSend else { return }
        cancelNavigation()
        let destination = destinationName(of: screen)
        phase = .sending
        let sent = await workspace.send(from: screen)
        guard case .sending = phase else { return }
        if sent, let delivered = window.selectedScreen {
            phase = .delivered(Delivery(screen: delivered, destination: destination))
        } else {
            phase = .composing
        }
    }

    private var isKey: Bool { workspace.keyWindow === window }

    func cancelNavigation() { draftNavigation.cancel() }

    @discardableResult
    private func carryingDraft(toHost hostID: UUID, _ retarget: @escaping @MainActor () async -> Bool) -> Task<Void, Never>? {
        guard case .composing = phase, isKey, let source = window.selectedScreen else { return nil }
        let sourceDestination = source.draftDestination
        let capturedDraft = source.currentDraft
        if let capturedDraft, let issue = source.draftMoveIssue(capturedDraft, toHost: hostID) {
            source.present(.draft(issue))
            return nil
        }
        return draftNavigation.retarget(retarget) { [weak self, weak source] in
            guard let self, let source, !source.isRetired, !Task.isCancelled else { return .retained }
            let loaded: ComposerDraft?
            if let capturedDraft { loaded = capturedDraft }
            else { loaded = await source.drafts.draft(for: sourceDestination) }
            guard let draft = loaded, !source.isRetired, !Task.isCancelled, case .composing = phase, isKey,
                  let destination = window.selectedScreen, !destination.isRetired,
                  destination.currentDraft !== draft,
                  await destination.prepareDraft(), !source.isRetired, !destination.isRetired,
                  !Task.isCancelled, case .composing = phase, isKey,
                  window.selectedScreen === destination, destination.currentDraft !== draft,
                  let destinationDraft = destination.currentDraft,
                  let document = destination.composerDocument, !document.isComposing else { return .retained }
            if let issue = source.draftMoveIssue(draft, toHost: destination.hostID) {
                destination.present(.draft(issue))
                return .retained
            }
            let content = source.drafts.document(for: draft).content
            let attachments = draft.attachments
            guard !content.runs.isEmpty || !attachments.isEmpty else { return .retained }
            @MainActor func reportTransferIssue(_ message: String) {
                guard !destination.isRetired, window.selectedScreen === destination,
                      destination.currentDraft === destinationDraft, case .composing = phase, isKey else { return }
                destination.present(.draft(message))
            }
            return await draftNavigation.commit {
                let sourceRevision = draft.revision
                guard let sourceReservation = source.drafts.reserveSubmission(of: draft) else { return .retained }
                defer { source.drafts.releaseSubmission(sourceReservation) }
                guard let destinationReservation = destination.drafts.reserveSubmission(of: destinationDraft) else { return .retained }
                defer { destination.drafts.releaseSubmission(destinationReservation) }
                let originalContent = document.content
                let originalAttachments = destination.composerAttachments
                let incoming = content.avoidingPasteIDs(Set(originalContent.pasted.map(\.id)))
                let separator: [ComposerDocumentContent.Run] = document.isEmpty ? [] : [.text("\n\n")]
                if !incoming.runs.isEmpty { document.edit(.append(.init(runs: separator + incoming.runs))) }
                let existingIDs = Set(originalAttachments.map(\.id))
                destination.composerAttachments += attachments.filter { !existingIDs.contains($0.id) }
                let destinationRevision = destinationDraft.revision
                let saved = await destination.drafts.flush()
                guard saved else {
                    if destination.drafts.applyTransfer(originalContent, attachments: originalAttachments,
                        to: destinationDraft, expectedRevision: destinationRevision) {
                        _ = await destination.drafts.flush()
                        reportTransferIssue("The draft couldn't be moved. It remains in the previous conversation.")
                        return .retained
                    }
                    reportTransferIssue("Both drafts changed during this move. Review them before moving again.")
                    return .stopped
                }
                guard source.drafts.applyTransfer(.init(runs: []), attachments: [], to: draft,
                    expectedRevision: sourceRevision) else {
                    if destination.drafts.applyTransfer(originalContent, attachments: originalAttachments,
                        to: destinationDraft, expectedRevision: destinationRevision) {
                        _ = await destination.drafts.flush()
                        return .retained
                    }
                    reportTransferIssue("Both drafts changed during this move. Review them before moving again.")
                    return .stopped
                }
                if !(await source.drafts.flush()) {
                    reportTransferIssue("This draft is saved here, but its previous copy could not be cleared. Retry saving the previous draft.")
                }
                return .moved
            }
        }
    }
}
