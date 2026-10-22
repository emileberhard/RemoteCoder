/// A multi-item selection stages each item separately but has only one local outcome.
@MainActor
final class AttachmentFeedbackBatch {
    private var remaining: Int
    private var failed = false
    private var cancelled = false
    private let feedback: (HapticEvent) -> Void

    init(count: Int, feedback: @escaping (HapticEvent) -> Void) {
        precondition(count > 0)
        remaining = count
        self.feedback = feedback
    }

    func finish(_ result: AttachmentStagingResult) {
        guard remaining > 0 else { return }
        remaining -= 1
        cancelled = cancelled || result == .cancelled
        if result == .failed { uploadFailed() }
        guard remaining == 0, !cancelled, !failed else { return }
        feedback(.commit)
    }

    func uploadFailed() {
        guard !cancelled, !failed else { return }
        failed = true
        feedback(.error)
    }
}
