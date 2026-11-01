import OSLog
import UIKit

@MainActor
final class PreparedSelectionPlayer: HapticInteractionPlaying {
    var hasActiveAccent: Bool { false }
    private weak var view: UIView?
    private var generator: UISelectionFeedbackGenerator?
    private var canPlay: @MainActor () -> Bool = { false }

    init(view: UIView) {
        self.view = view
    }

    func prepare(strength: HapticStrength, canPlay: @escaping @MainActor () -> Bool) {
        self.canPlay = canPlay
        guard canPlay(), let view else { return }
        generator = UISelectionFeedbackGenerator(view: view)
        generator?.prepare()
    }

    func play(_ event: HapticEvent) {
        guard event == .selection, canPlay() else { return }
        OSSignposter(subsystem: "RemoteCoder", category: "Haptics").emitEvent("feedback-api-request", "selection")
        generator?.selectionChanged()
    }

    func finish() { cancel() }

    func cancel() {
        if let generator { generator.view?.removeInteraction(generator) }
        generator = nil
        canPlay = { false }
    }
}
