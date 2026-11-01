import CoreHaptics
import SwiftUI
import UIKit

extension HapticService {
    static let shared = HapticService(
        defaults: .standard,
        supportsHaptics: CHHapticEngine.capabilitiesForHardware().supportsHaptics,
        isActive: { UIApplication.shared.applicationState == .active },
        makeInteractionPlayer: { PreparedHapticPlayer(native: $0) },
        makeStreamingPlayer: { PreparedStreamingHapticPlayer() }
    )

    func beginSelectionInteraction(owner: UUID, in view: UIView) {
        beginInteraction(owner: owner) { PreparedSelectionPlayer(view: view) }
    }

    func copy(_ text: String) {
        Pasteboard.copy(text)
        play(.copied)
    }
}

struct HapticAttachment: UIViewRepresentable {
    var service: HapticService = .shared

    func makeUIView(context: Context) -> AttachmentView { AttachmentView(service: service) }
    func updateUIView(_ view: AttachmentView, context: Context) {}
    static func dismantleUIView(_ view: AttachmentView, coordinator: ()) { view.detach() }

    final class AttachmentView: UIView {
        private let service: HapticService
        private var player: ViewHapticPlayer?

        init(service: HapticService) {
            self.service = service
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard let window else { return }
            let player = ViewHapticPlayer(view: window)
            self.player = player
            service.attach(player)
        }

        func detach() {
            if let player { service.detach(player) }
            player = nil
        }
    }
}
