#if os(macOS)
import AppKit
import os
import SwiftUI

extension HapticService {
    static let shared = HapticService(
        defaults: AppStorageScope.current.defaults,
        supportsHaptics: false,
        isActive: { NSApplication.shared.isActive },
        makeInteractionPlayer: { NoHapticPlayer() }
    )

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

@MainActor
final class NoHapticPlayer: HapticInteractionPlaying {
    func prepare(strength: HapticStrength, canPlay: @escaping @MainActor () -> Bool) {}
    func play(_ event: HapticEvent) {}
    func finish() {}
    func cancel() {}
}

struct HapticOutput: View {
    var service: HapticService = .shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .sensoryFeedback(trigger: service.pulse) { _, pulse in service.feedback(for: pulse) }
            .onChange(of: scenePhase) { if scenePhase != .active { service.cancelInteractions() } }
            .onDisappear { service.cancelInteractions() }
    }
}
#endif
