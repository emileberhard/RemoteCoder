import Foundation

/// One Advanced buffer and the exact form snapshot it was derived from. Dirty
/// text is never regenerated implicitly, and asynchronous results commit only
/// against the form and text captured before parsing started.
struct AutomationDocumentState: Equatable, Sendable {
    var text = ""
    private(set) var baseDefinition: AutomationDefinition?
    private(set) var baseText: String?
    var isDirty: Bool { baseText.map { text != $0 } ?? !text.isEmpty }
    func conflicts(with definition: AutomationDefinition) -> Bool {
        isDirty && baseDefinition != definition
    }
    mutating func installClean(_ text: String, definition: AutomationDefinition) {
        self.text = text; baseText = text; baseDefinition = definition
    }
    mutating func keepTextAgainst(_ definition: AutomationDefinition) { baseDefinition = definition }
    func canApply(capturedText: String, capturedDefinition: AutomationDefinition, currentDefinition: AutomationDefinition) -> Bool {
        text == capturedText && capturedDefinition == currentDefinition && baseDefinition == currentDefinition
    }
}
