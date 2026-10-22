import Foundation

struct AutomationMutation: Equatable, Sendable {
    enum Operation: Equatable, Sendable { case save, remove, restore, run }
    let operation: Operation
    let request: AutomationRequest
}

struct AutomationOperationOutcome: Equatable, Sendable {
    let message: String?
    let admittedRunID: String?
    let fields: [AutomationValidationField]

    static func committed(_ result: JSONValue, mutation: AutomationMutation) -> Self {
        let body = result.objectValue
        let runID = body?["runs"]?.arrayValue?.first?.stringValue ?? body?["run_id"]?.stringValue ?? body?["id"]?.stringValue
        let isAdmission = mutation.operation == .run && mutation.request.id != nil
        let message: String?
        if isAdmission { message = runID == nil ? body?["reason"]?.stringValue ?? "No run was admitted. Review the event or precondition." : nil }
        else if mutation.request.cancel == true {
            if let state = body?["state"]?.stringValue { message = "Run status: " + state.capitalized }
            else { message = "Cancellation requested." }
        }
        else { message = "Operation committed." }
        return Self(message: message, admittedRunID: isAdmission ? runID : nil, fields: [])
    }
}

/// A specific management operation survives its view. One exact attempt owns
/// both settlement and release; stale callbacks cannot touch a later operation.
struct AutomationOperationState: Equatable, Sendable {
    struct Attempt: Equatable, Sendable {
        let id: UUID
        let mutation: AutomationMutation
        let hadPendingAtStart: Bool
    }
    private(set) var pending: AutomationMutation?
    private(set) var inFlight: Attempt?
    private(set) var outcome: AutomationOperationOutcome?
    var isInFlight: Bool { inFlight != nil }

    mutating func begin(_ mutation: AutomationMutation) -> Attempt? {
        guard inFlight == nil, pending == nil || pending == mutation else { return nil }
        let attempt = Attempt(id: UUID(), mutation: mutation, hadPendingAtStart: pending != nil)
        pending = mutation; inFlight = attempt; outcome = nil
        return attempt
    }

    @discardableResult mutating func finish(_ attempt: Attempt, outcome: AutomationOperationOutcome, retainingPending: Bool) -> Bool {
        guard inFlight == attempt, pending == attempt.mutation else { return false }
        self.outcome = outcome
        if !retainingPending { pending = nil }
        inFlight = nil
        return true
    }
}
