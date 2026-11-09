import OSLog
import UIKit

@MainActor
final class ViewHapticPlayer: HapticNativePlaying {
    private weak var view: UIView?
    private var impacts: [HapticRecipe.Impact: UIImpactFeedbackGenerator] = [:]
    private var selection: UISelectionFeedbackGenerator?
    private var notification: UINotificationFeedbackGenerator?
    private let signposter = OSSignposter(subsystem: "RemoteCoder", category: "Haptics")

    init(view: UIView) { self.view = view }

    func isAttached(to view: UIView) -> Bool { self.view === view }

    func prepare(_ recipe: HapticRecipe) {
        switch recipe {
        case let .impact(style, _): impact(for: style)?.prepare()
        case .selection: selectionGenerator()?.prepare()
        case .success, .warning, .error: notificationGenerator()?.prepare()
        }
    }

    func play(_ event: HapticEvent) {
        let recipe = event.recipe
        switch recipe {
        case let .impact(style, intensity):
            guard let impact = impact(for: style) else { return }
            signposter.emitEvent("feedback-api-request", "\(event.rawValue, privacy: .public)")
            impact.impactOccurred(intensity: intensity)
            impact.prepare()
        case .selection:
            guard let selection = selectionGenerator() else { return }
            signposter.emitEvent("feedback-api-request", "\(event.rawValue, privacy: .public)")
            selection.selectionChanged()
            selection.prepare()
        case .success, .warning, .error:
            guard let notification = notificationGenerator() else { return }
            signposter.emitEvent("feedback-api-request", "\(event.rawValue, privacy: .public)")
            notification.notificationOccurred(recipe == .success ? .success : recipe == .warning ? .warning : .error)
        }
    }

    func release() {
        for generator in impacts.values { generator.view?.removeInteraction(generator) }
        if let selection { selection.view?.removeInteraction(selection) }
        if let notification { notification.view?.removeInteraction(notification) }
        impacts.removeAll()
        selection = nil
        notification = nil
    }

    private func impact(for style: HapticRecipe.Impact) -> UIImpactFeedbackGenerator? {
        if let generator = impacts[style] { return generator }
        guard let view else { return nil }
        let generator = UIImpactFeedbackGenerator(style: style.uiStyle, view: view)
        impacts[style] = generator
        return generator
    }

    private func selectionGenerator() -> UISelectionFeedbackGenerator? {
        if let selection { return selection }
        guard let view else { return nil }
        let generator = UISelectionFeedbackGenerator(view: view)
        selection = generator
        return generator
    }

    private func notificationGenerator() -> UINotificationFeedbackGenerator? {
        if let notification { return notification }
        guard let view else { return nil }
        let generator = UINotificationFeedbackGenerator(view: view)
        notification = generator
        return generator
    }
}
