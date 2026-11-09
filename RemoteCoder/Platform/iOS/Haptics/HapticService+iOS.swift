import CoreHaptics
import SwiftUI
import UIKit

extension HapticService {
    static let shared = HapticService(
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

struct HapticAttachment: View {
    var service: HapticService = .shared
    let voiceCall: VoiceCall
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        WindowAttachment(service: service)
            .frame(width: 0, height: 0)
            .onChange(of: scenePhase) { if scenePhase != .active { service.cancelPlayback() } }
            .onChange(of: voiceCall.isActive) { _, active in
                if active { service.cancelPlayback() }
            }
            .onDisappear { service.cancelPlayback() }
    }

    private struct WindowAttachment: UIViewRepresentable {
        let service: HapticService

        func makeUIView(context: Context) -> AttachmentView { AttachmentView(service: service) }
        func updateUIView(_ view: AttachmentView, context: Context) {}
        static func dismantleUIView(_ view: AttachmentView, coordinator: ()) { view.detach() }
    }

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
            guard let window, player?.isAttached(to: window) != true else { return }
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
