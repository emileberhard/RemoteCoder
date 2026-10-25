import Foundation
import SwiftUI

/// One drawer listing every configured gateway's conversations.
///
/// Rows are addressed by host and thread, so two gateways exposing the same
/// thread id stay two separate rows with their own pins and selection.
struct ConversationHistoryView: View {
    var workspace: ChatWorkspaceModel
    let window: ChatWindowModel
    let isOpen: Bool
    @Binding var layout: ConversationDrawerLayout?
    @Binding var notice: DrawerNotice?

    @State private var sidebar: ConversationSidebarSnapshot?
    #if os(iOS)
    @State private var rising: Set<String> = []
    @State private var animationID = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #endif
    @State private var pending: ConversationSidebarSnapshot?
    @State private var isInteracting = false
    @State private var undo: DrawerUndo?
    @State private var pinNameIntent: PinNameIntent?
    @State private var pinNameDraft = ""
    @State private var windowActivations = 0
    @State private var capturedWindowActivation: Int?
    @Environment(\.visualsVisible) private var visualsVisible

    let onSelect: (ConversationAddress) -> ChatWorkspaceModel.ConversationSwitchOutcome
    let onOpenDraft: (UnsentDraftAddress) -> Void
    let onStartNew: (UUID) -> Void
    let onShowSettings: () -> Void
    let onFork: (ConversationAddress) -> Void
    let onFocusComposer: () -> Void

    var body: some View {
        historyList
            .alert(pinNamePromptTitle, item: $pinNameIntent) { intent in
                TextField("Pinned chat name", text: $pinNameDraft)
                    .onChange(of: pinNameDraft) { pinNameDraft = ConversationPinName.clamped(pinNameDraft) }
                Button(intent.primaryActionTitle) {
                    commitPinName(intent)
                }
                .disabled(pinNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {
                    pinNameDraft = ""
                }
            } message: { intent in
                Text(intent.promptMessage)
            }
            .modifier(WindowActivations(count: $windowActivations))
            .task(id: Arrangement(isOpen: isOpen, isVisible: visualsVisible, windowActivations: windowActivations)) {
                guard isOpen && visualsVisible else { capturedWindowActivation = nil; return }
                let capturedLayout: ConversationDrawerLayout
                if let layout, capturedWindowActivation == windowActivations {
                    capturedLayout = layout
                } else {
                    capturedLayout = workspace.captureDrawerOpening(at: .now, in: window)
                    layout = capturedLayout
                    capturedWindowActivation = windowActivations
                }
                pending = nil
                isInteracting = false
                for await snapshot in Observations({ @MainActor [workspace, window] in
                    workspace.sidebarSnapshot(arrangedBy: layout ?? capturedLayout, in: window)
                }) {
                    guard !Task.isCancelled else { return }
                    if let admitted = snapshot.admittedLayout, admitted != layout { layout = admitted }
                    receive(snapshot)
                }
            }
            .task(id: SearchRequest(isOpen: isOpen && visualsVisible, query: window.drawerQuery)) {
                guard isOpen && visualsVisible, !window.drawerQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                await workspace.loadOlderHistory(in: window)
            }
            .task(id: notice) {
                guard notice != nil else { return }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                notice = nil
            }
            .task(id: undo) {
                guard undo != nil else { return }
                do { try await Task.sleep(for: DrawerUndo.lifetime) } catch { return }
                undo = nil
            }
    }

    private var historyList: some View {
        #if os(macOS)
        ConversationHistoryList(workspace: workspace, window: window, snapshot: presented, notice: notice, undo: undo,
                                actions: actions, onUndo: performUndo, onInteractionChanged: interactionChanged)
        #else
        ConversationHistoryList(workspace: workspace, window: window, snapshot: presented, notice: notice, undo: undo,
                                actions: actions, onUndo: performUndo, risingRowIDs: rising, onInteractionChanged: interactionChanged)
        #endif
    }

    private func receive(_ snapshot: ConversationSidebarSnapshot) {
        guard snapshot != sidebar else { pending = nil; return }
        if isInteracting, let sidebar, sidebar.items.map(\.id) != snapshot.items.map(\.id) {
            pending = snapshot
            apply(snapshot.heldInLayout(of: sidebar))
        } else {
            pending = nil
            apply(snapshot)
        }
    }

    private func interactionChanged(_ interacting: Bool) {
        isInteracting = interacting
        guard !interacting, let pending else { return }
        self.pending = nil
        apply(pending)
    }

    private func apply(_ snapshot: ConversationSidebarSnapshot) {
        guard snapshot != sidebar else { return }
        #if os(macOS)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { sidebar = snapshot }
        #else
        let previous = sidebar?.items ?? []
        let changesOrder = previous.map(\.id) != snapshot.items.map(\.id)
        guard changesOrder, sidebar != nil, !reduceMotion else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if changesOrder {
                    animationID = UUID()
                    rising = []
                }
                sidebar = snapshot
            }
            return
        }
        let id = UUID()
        animationID = id
        withAnimation(.smooth(duration: 0.35)) {
            rising = ConversationSidebarItem.risingRowIDs(from: previous, to: snapshot.items)
            sidebar = snapshot
        } completion: {
            guard animationID == id else { return }
            rising = []
        }
        #endif
    }

    private struct Arrangement: Equatable {
        let isOpen: Bool
        let isVisible: Bool
        let windowActivations: Int
    }

    private struct SearchRequest: Equatable {
        let isOpen: Bool
        let query: String
    }

    private var presented: ConversationSidebarSnapshot? {
        sidebar ?? (isOpen && visualsVisible ? workspace.sidebarSnapshot(arrangedBy: .live(at: .now), in: window) : nil)
    }

    private var actions: ConversationHistoryActions {
        ConversationHistoryActions(
            open: onSelect,
            pin: beginPinning,
            rename: beginRenaming,
            regenerateName: { address in
                HapticService.shared.play(.commit)
                workspace.regenerateTitle(at: address) { message in
                    notice = DrawerNotice(message: message)
                }
            },
            unpin: { address in
                rearrange {
                    workspace.unpin(address)
                    HapticService.shared.play(.toggleOff)
                }
            },
            fork: onFork,
            markRead: { addresses in
                workspace.markRead(addresses)
                HapticService.shared.play(.toggleOff)
            },
            markUnread: { address in
                workspace.markUnread(address)
                HapticService.shared.play(.toggleOn)
            },
            settle: settle,
            unsettle: unsettle,
            openDraft: onOpenDraft,
            discardDraft: discardDraft,
            startNew: onStartNew,
            showSettings: onShowSettings,
            focusComposer: onFocusComposer
        )
    }

    private func settle(_ addresses: [ConversationAddress]) {
        var settled: [ExecutionTarget: [ConversationSettlementEdit]] = [:]
        rearrange { settled = workspace.settle(addresses) }
        guard let settledUndo = DrawerUndo(settled: settled) else { return }
        HapticService.shared.play(.commit)
        undo = settledUndo
    }

    private func unsettle(_ addresses: [ConversationAddress]) {
        rearrange { workspace.unsettle(addresses) }
        HapticService.shared.play(.commit)
    }

    private func discardDraft(_ address: UnsentDraftAddress) {
        switch workspace.discardUnsentDraft(address, undoWindow: DrawerUndo.lifetime + .seconds(1)) {
        case .discarded(let wasShown):
            HapticService.shared.play(.commit)
            undo = DrawerUndo(discardedDraft: address, reopens: wasShown)
        case .refusedWhileDictating:
            let refusal = DrawerNotice(message: "Finish dictating before discarding a draft.")
            notice = refusal
            HapticService.shared.play(.refused)
            AccessibilityNotification.Announcement(refusal.message).post()
        }
    }

    private func performUndo() {
        guard let undo else { return }
        self.undo = nil
        switch undo.action {
        case .settled(let settled): rearrange { workspace.undoSettle(settled) }
        case .discardedDraft(let address, let reopens):
            workspace.restoreUnsentDraft(address)
            if reopens { onOpenDraft(address) }
        }
        HapticService.shared.play(.commit)
    }
}

extension ConversationHistoryView {
    /// The pin prompt's source of truth is the addressed row itself, so a pin
    /// command can never land on the same thread id on another host.
    fileprivate struct PinNameIntent: Identifiable {
        enum Kind { case pin, rename }

        let kind: Kind
        let address: ConversationAddress
        let title: String

        var id: String { "\(kind)|\(address.id)" }

        var primaryActionTitle: String {
            switch kind {
            case .pin: "Pin"
            case .rename: "Rename"
            }
        }

        var promptMessage: String {
            switch kind {
            case .pin: "Pinned chats need a name."
            case .rename: "Update the pinned chat name."
            }
        }
    }

    private var pinNamePromptTitle: String {
        switch pinNameIntent?.kind {
        case .pin: "Name this pinned chat"
        case .rename: "Rename pinned chat"
        case nil: ""
        }
    }

    private func beginPinning(_ row: ConversationSidebarRow) {
        pinNameDraft = ""
        pinNameIntent = PinNameIntent(kind: .pin, address: row.address, title: row.title)
    }

    private func beginRenaming(_ row: ConversationSidebarRow) {
        pinNameDraft = workspace.pinnedName(for: row.address) ?? ""
        pinNameIntent = PinNameIntent(kind: .rename, address: row.address, title: row.title)
    }

    private func rearrange(_ change: () -> Void) {
        change()
        if let layout { receive(workspace.sidebarSnapshot(arrangedBy: layout, in: window)) }
    }

    private func commitPinName(_ intent: PinNameIntent) {
        let trimmed = pinNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        pinNameDraft = ""
        guard trimmed.isEmpty == false else { return }
        let previous = workspace.pinnedName(for: intent.address)
        rearrange { workspace.pin(intent.address, name: trimmed) }
        if workspace.pinnedName(for: intent.address) != previous {
            HapticService.shared.play(intent.kind == .pin ? .toggleOn : .commit)
        }
    }
}

struct HostStatusText: View {
    let state: ConversationSidebarHostState
    let namingHost: Bool

    var body: some View {
        switch state.status {
        case .updating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(verbatim: namingHost ? "Updating \(state.hostName)…" : "Updating the gateway…")
            }
            .lineLimit(3)
            .foregroundStyle(.secondary)
        case .failed(let message):
            Text(verbatim: namingHost ? "\(state.hostName): \(message)" : message)
                .lineLimit(3)
                .foregroundStyle(.red)
        case nil:
            EmptyView()
        }
    }
}

struct DrawerNotice: Equatable {
    let id = UUID()
    let message: String
}

struct DrawerUndo: Equatable {
    enum Action: Equatable {
        case settled([ExecutionTarget: [ConversationSettlementEdit]])
        case discardedDraft(UnsentDraftAddress, reopens: Bool)
    }

    static let lifetime = Duration.seconds(5)

    let id = UUID()
    let message: String
    let action: Action

    init?(settled: [ExecutionTarget: [ConversationSettlementEdit]]) {
        let count = settled.values.reduce(0) { $0 + $1.count }
        guard count > 0 else { return nil }
        message = count == 1 ? "Settled" : "Settled \(count) chats"
        action = .settled(settled)
    }

    init(discardedDraft address: UnsentDraftAddress, reopens: Bool) {
        message = "Draft discarded"
        action = .discardedDraft(address, reopens: reopens)
    }
}
