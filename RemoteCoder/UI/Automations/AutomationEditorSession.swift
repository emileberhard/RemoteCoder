import Foundation
import Observation

@MainActor @Observable
final class AutomationEditorSession: Identifiable {
    let id = UUID()
    var draft: AutomationDraft
    var reason = ""
    private(set) var pending: AutomationMutation?
    private(set) var error: String?
    private(set) var conflict: AutomationDetail?
    private(set) var isSaving = false
    var document = AutomationDocumentState()
    var advancedError: String?
    private(set) var isPreparingAdvanced = false
    private(set) var isApplyingAdvanced = false
    private(set) var validationFields: [AutomationValidationField] = []
    var comparison: AutomationComparison?

    init(draft: AutomationDraft) { self.draft = draft }

    func save(using authority: AutomationManagement) async -> Bool {
        guard !isSaving, !isPreparingAdvanced, !isApplyingAdvanced, !document.isDirty else { return false }
        let pendingBeforeAttempt = pending
        isSaving = true
        defer { isSaving = false }
        // Freeze both payload and ID until acknowledgement is resolved. Editing
        // is disabled during uncertainty so Retry cannot become a different save.
        var request = draft.sourceRevision == nil ? draft.saveRequest(requestID: UUID().uuidString) : draft.restoreRequest(requestID: UUID().uuidString, enabled: draft.definition.enabled)
        request.reason = reason.isEmpty ? nil : reason
        let mutation = pending ?? AutomationMutation(operation: draft.sourceRevision == nil ? .save : .restore, request: request)
        pending = mutation
        do {
            _ = try await authority.mutate(mutation)
            pending = nil; error = nil; conflict = nil; validationFields = []
            return true
        } catch let unavailable as AutomationManagementError {
            if pendingBeforeAttempt == nil { pending = nil } // This retry cannot settle an earlier unknown save.
            error = unavailable.localizedDescription
        } catch let failure as AutomationServiceError {
            pending = nil; error = failure.localizedDescription; validationFields = failure.fields ?? []
            if failure.isConflict {
                do {
                    conflict = try await authority.detail(draft.definition.id)
                    if let conflict { comparison = try await AutomationDocuments.compare(conflict.definition, draft.definition) }
                } catch { self.error = "\(failure.localizedDescription)\nCould not load current revision: \(error.localizedDescription)" }
            }
        } catch {
            // Transport may have lost the acknowledgement. Keep the exact request
            // for a deliberate retry; never schedule an offline save.
            if AutomationMutationFailure.acknowledgementUnknown(error) {
                self.error = "\(error.localizedDescription)\nSave acknowledgement is unknown. Retry the same save after reconnecting."
            } else {
                if !AutomationMutationFailure.keepPendingAfterFailure(error, alreadyPending: pendingBeforeAttempt != nil) { pending = nil }
                self.error = error.localizedDescription
            }
        }
        return false
    }

    func useCurrent() {
        guard let conflict else { return }
        draft = AutomationDraft(definition: conflict.definition, expectedRevision: conflict.revision)
        self.conflict = nil; comparison = nil; error = nil; pending = nil; document = AutomationDocumentState(); advancedError = nil; validationFields = []
    }
    func rebaseDraft() {
        guard let conflict else { return }
        draft.expectedRevision = conflict.revision
        self.conflict = nil; comparison = nil; error = nil; pending = nil
    }
    func reconcile(using authority: AutomationManagement) async -> Bool {
        guard let pending, let id = pending.request.requestId, !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            // Receipts are authoritative even if another edit has since changed head.
            _ = try await authority.gateway.showAutomationReceipt(id)
            self.pending = nil; error = nil
            await authority.refreshCachedInventories()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func prepareAdvanced(discardText: Bool = false) async {
        guard !isPreparingAdvanced, !isApplyingAdvanced else { return }
        if discardText { document = AutomationDocumentState() }
        guard !document.isDirty, document.baseDefinition != draft.definition else { return }
        isPreparingAdvanced = true; defer { isPreparingAdvanced = false }
        let capturedDraft = draft
        let capturedText = document.text
        do {
            let text = try await AutomationDocuments.pretty(.object(capturedDraft.definition.fields))
            guard draft == capturedDraft, document.text == capturedText, !document.isDirty else { return }
            document.installClean(text, definition: capturedDraft.definition); advancedError = nil
        } catch { advancedError = error.localizedDescription }
    }
    func keepAdvancedAgainstForm() { document.keepTextAgainst(draft.definition); advancedError = nil }
    func applyAdvanced() async {
        guard !isApplyingAdvanced, !isSaving, pending == nil else { return }
        guard document.baseDefinition == draft.definition else {
            advancedError = "The form changed since this text was prepared. Choose which version to keep before applying."; return
        }
        isApplyingAdvanced = true; defer { isApplyingAdvanced = false }
        let capturedDraft = draft
        let capturedText = document.text
        do {
            let fields = try await AutomationDocuments.parseObject(capturedText)
            guard capturedDraft == draft, document.canApply(capturedText: capturedText, capturedDefinition: capturedDraft.definition, currentDefinition: draft.definition) else {
                advancedError = "The form or Advanced text changed while parsing. Review the changes and apply again."; return
            }
            guard fields["id"]?.stringValue == draft.definition.id else {
                advancedError = "The automation ID cannot be changed here."; return
            }
            let definition = AutomationDefinition(fields: fields)
            draft.definition = definition
            document.installClean(capturedText, definition: definition); advancedError = nil; validationFields = []
        } catch { advancedError = error.localizedDescription }
    }
}
