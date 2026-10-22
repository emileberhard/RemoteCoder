import SwiftUI

struct ComposerInputActions {
    let send: @MainActor () -> Void
    let lastSentPrompt: @MainActor () -> ComposerDocumentContent?
    let stop: @MainActor () -> Bool
    let attach: @MainActor (ComposerPaste<PastedImage>) -> Void
    let openPastedText: @MainActor (UUID) -> Void
    let dropTargetChanged: @MainActor (Bool) -> Void
}
