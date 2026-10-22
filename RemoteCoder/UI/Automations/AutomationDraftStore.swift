import Foundation
import Observation

/// Workspace-owned Settings drafts survive editor dismissal, navigation and Settings
/// reopening and chat-window replacement. This is presentation state, never an offline mutation queue.
@MainActor @Observable
final class AutomationDraftStore {
    private(set) var sessions: [String: AutomationEditorSession] = [:]
    private(set) var operations: [String: AutomationOperationState] = [:]
    @ObservationIgnored private var completedOrder: [String] = []
    var isFull: Bool { sessions.count >= 20 }
    func session(authorityID: UUID, draft: AutomationDraft) -> AutomationEditorSession? {
        let key = key(authorityID: authorityID, draft: draft)
        if let existing = sessions[key] { return existing }
        guard !isFull else { return nil }
        let session = AutomationEditorSession(draft: draft)
        sessions[key] = session
        return session
    }
    func drafts(authorityID: UUID) -> [AutomationEditorSession] {
        sessions.filter { $0.key.hasPrefix(authorityID.uuidString + "|") }.map(\.value)
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }
    func discard(_ session: AutomationEditorSession) {
        sessions = sessions.filter { $0.value.id != session.id }
    }
    func operation(_ key: String) -> AutomationOperationState { operations[key] ?? AutomationOperationState() }
    func begin(_ mutation: AutomationMutation, key: String) -> AutomationOperationState.Attempt? {
        if operations[key] == nil, operations.count >= 20 {
            guard let oldest = completedOrder.first(where: { operations[$0]?.pending == nil && operations[$0]?.isInFlight == false }) else { return nil }
            operations.removeValue(forKey: oldest); completedOrder.removeAll { $0 == oldest }
        }
        var state = operation(key)
        guard let attempt = state.begin(mutation) else { return nil }
        operations[key] = state
        return attempt
    }
    @discardableResult func finish(_ attempt: AutomationOperationState.Attempt, key: String,
                                  outcome: AutomationOperationOutcome, retainingPending: Bool) -> Bool {
        guard var state = operations[key], state.finish(attempt, outcome: outcome, retainingPending: retainingPending) else { return false }
        operations[key] = state
        completedOrder.removeAll { $0 == key }; completedOrder.append(key)
        return true
    }
    private func key(authorityID: UUID, draft: AutomationDraft) -> String {
        "\(authorityID.uuidString)|\(draft.definition.id.isEmpty ? "new" : draft.definition.id)|\(draft.sourceRevision.map(String.init) ?? "edit")"
    }
}
