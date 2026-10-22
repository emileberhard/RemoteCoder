#if os(macOS)
import AppKit
import Observation

@MainActor
@Observable
final class AttentionCenter {
    enum Action: Sendable {
        case open(ConversationAddress)
        case newChat
        case newWindow
        case showApp
    }

    static let entryLimit = 8

    private(set) var summary: AttentionSummary
    @ObservationIgnored private let workspace: ChatWorkspaceModel
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var settlementWake: (at: Date, task: Task<Void, Never>)?
    @ObservationIgnored private var clockObserver: (any NSObjectProtocol)?

    init(workspace: ChatWorkspaceModel) {
        self.workspace = workspace
        summary = AttentionSummary(hosts: workspace.attentionInputs(), limit: Self.entryLimit, at: .now)
    }

    func start() {
        guard observation == nil else { return }
        observation = Task { [weak self, workspace] in
            for await summary in Observations({ @MainActor in
                AttentionSummary(hosts: workspace.attentionInputs(), limit: Self.entryLimit, at: .now)
            }) {
                self?.publish(summary)
            }
        }
        clockObserver = NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
        settlementWake?.task.cancel()
        settlementWake = nil
        clockObserver.map(NotificationCenter.default.removeObserver)
        clockObserver = nil
    }

    func perform(_ action: Action) {
        NSApplication.shared.activate()
        switch action {
        case .open(let address):
            workspace.events.summon(.open(.conversation(address)))
        case .newChat:
            workspace.events.summon(.quickAction(RemoteCoderQuickActionRequest(action: .newChat)))
        case .newWindow:
            workspace.events.summon(.open(.newChat(slot: UUID())))
        case .showApp:
            if !workspace.hasOpenWindow { workspace.events.openMainWindow() }
        }
    }

    private func publish(_ next: AttentionSummary) {
        if next != summary { summary = next }
        let dockTile = NSApplication.shared.dockTile
        if dockTile.badgeLabel != next.badgeLabel { dockTile.badgeLabel = next.badgeLabel }
        scheduleSettlementWake(at: next.nextAutomaticSettlement)
    }

    private func refresh() {
        settlementWake?.task.cancel()
        settlementWake = nil
        publish(AttentionSummary(hosts: workspace.attentionInputs(), limit: Self.entryLimit, at: .now))
    }

    private func scheduleSettlementWake(at date: Date?) {
        guard settlementWake?.at != date else { return }
        settlementWake?.task.cancel()
        settlementWake = date.map { date in
            (date, Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(1, date.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                self?.refresh()
            })
        }
    }
}
#endif
