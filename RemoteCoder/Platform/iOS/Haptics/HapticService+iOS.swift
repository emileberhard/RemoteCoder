import CoreHaptics
import SwiftUI
import os
import UIKit

extension HapticService {
    static let shared = HapticService(
        defaults: .standard,
        supportsHaptics: CHHapticEngine.capabilitiesForHardware().supportsHaptics,
        isActive: { UIApplication.shared.applicationState == .active },
        makeInteractionPlayer: { PreparedHapticPlayer() }
    )

    /// Touch feedback stays on the control's SwiftUI transaction, without a second state hop.
    func feedbackForInteraction(_ event: HapticEvent) -> SensoryFeedback? {
        accept(event) ? event.recipe(for: strength).feedback : nil
    }

    func feedback(for pulse: HapticPulse?) -> SensoryFeedback? {
        guard let pulse, canPlay(pulse.event), pulse.strength == strength, pulse.isFresh(at: .now) else { return nil }
        signposter.emitEvent("feedback-api-request", "\(pulse.event.rawValue, privacy: .public)")
        return pulse.event.recipe(for: pulse.strength).feedback
    }

    func copy(_ text: String) {
        Pasteboard.copy(text)
        play(.copied)
    }
}

extension HapticRecipe {
    var feedback: SensoryFeedback {
        switch self {
        case let .impact(.light, intensity): .impact(weight: .light, intensity: intensity)
        case let .impact(.medium, intensity): .impact(weight: .medium, intensity: intensity)
        case let .impact(.rigid, intensity): .impact(flexibility: .rigid, intensity: intensity)
        case let .impact(.soft, intensity): .impact(flexibility: .soft, intensity: intensity)
        case .selection: .selection
        case .success: .success
        case .warning: .warning
        case .error: .error
        }
    }
}

/// App-lifetime output survives a button/card/sheet disappearing after local acceptance.
struct HapticOutput: View {
    var service: HapticService = .shared
    let voiceCall: VoiceCall
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .sensoryFeedback(trigger: service.pulse) { _, pulse in service.feedback(for: pulse) }
            .onChange(of: scenePhase) { if scenePhase != .active { service.cancelInteractions() } }
            .onChange(of: voiceCall.isActive) { _, active in
                if active { service.cancelInteractions() }
            }
            .onDisappear { service.cancelInteractions() }
    }
}
