import OSLog
import UIKit

@MainActor
final class PreparedSelectionPlayer: HapticInteractionPlaying {
    var hasActiveAccent: Bool { false }
    private let signposter = OSSignposter(subsystem: "RemoteCoder", category: "Haptics")
    private weak var view: UIView?
    private var generator: UISelectionFeedbackGenerator?
    private var canPlay: @MainActor () -> Bool = { false }

    init(view: UIView) {
        self.view = view
    }

    func prepare(canPlay: @escaping @MainActor () -> Bool) {
        self.canPlay = canPlay
        guard canPlay(), let view else { return }
        generator = UISelectionFeedbackGenerator(view: view)
        generator?.prepare()
    }

    func play(_ event: HapticEvent) {
        guard event == .selection, canPlay(), let generator else { return }
        signposter.emitEvent("feedback-api-request", "\(event.rawValue, privacy: .public)")
        generator.selectionChanged()
    }

    func finish() { cancel() }

    func cancel() {
        if let generator { generator.view?.removeInteraction(generator) }
        generator = nil
        canPlay = { false }
    }
}
