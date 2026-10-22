import CoreHaptics
import OSLog
import UIKit

extension HapticRecipe.Impact {
    var uiStyle: UIImpactFeedbackGenerator.FeedbackStyle {
        switch self {
        case .light: .light
        case .medium: .medium
        case .rigid: .rigid
        case .soft: .soft
        }
    }
}

extension HapticAccent {
    func makePattern() throws -> CHHapticPattern {
        switch self {
        case .lift:
            return try CHHapticPattern(events: [
                CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    .init(parameterID: .hapticIntensity, value: 0.3),
                    .init(parameterID: .hapticSharpness, value: 0.25)
                ], relativeTime: 0, duration: 0.035),
                CHHapticEvent(eventType: .hapticTransient, parameters: [
                    .init(parameterID: .hapticIntensity, value: 0.95),
                    .init(parameterID: .hapticSharpness, value: 0.85)
                ], relativeTime: 0.035)
            ], parameters: [])
        case .seat:
            return try CHHapticPattern(events: [
                CHHapticEvent(eventType: .hapticTransient, parameters: [
                    .init(parameterID: .hapticIntensity, value: 0.8),
                    .init(parameterID: .hapticSharpness, value: 0.55)
                ], relativeTime: 0),
                CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    .init(parameterID: .hapticIntensity, value: 0.3),
                    .init(parameterID: .hapticSharpness, value: 0.2)
                ], relativeTime: 0.01, duration: 0.065)
            ], parameterCurves: [
                .init(parameterID: .hapticIntensityControl, controlPoints: [
                    .init(relativeTime: 0, value: 1),
                    .init(relativeTime: 0.075, value: 0)
                ], relativeTime: 0)
            ])
        }
    }
}

/// One gesture owns these resources. No task hop for ticks, no replay after warm-up,
/// no file loading or keep-warm timer, and no changes to the app's audio session.
@MainActor
final class PreparedHapticPlayer: HapticInteractionPlaying {
    private var impacts: [HapticRecipe.Impact: UIImpactFeedbackGenerator] = [:]
    private var selection: UISelectionFeedbackGenerator?
    private var notification: UINotificationFeedbackGenerator?
    private var engine: CHHapticEngine?
    private var players: [HapticAccent: any CHHapticPatternPlayer] = [:]
    private var activePlayer: (any CHHapticPatternPlayer)?
    private var engineGeneration = UUID()
    private var ready = false
    private var ending = false
    private var strength: HapticStrength = .standard
    private var canPlay: @MainActor () -> Bool = { false }
    private let logger = Logger(subsystem: "RemoteCoder", category: "Haptics")

    func prepare(strength: HapticStrength, canPlay: @escaping @MainActor () -> Bool) {
        self.strength = strength
        self.canPlay = canPlay
        guard !ending, canPlay() else { return }
        for event in [HapticEvent.buttonPress, .selection, .commit, .sliderStep, .sliderGrab, .lift, .sliderMinimum, .sliderMaximum, .sliderRelease, .sliderSettle] {
            switch event.recipe(for: strength) {
            case let .impact(style, _): impact(for: style).prepare()
            case .selection:
                selection = UISelectionFeedbackGenerator()
                selection?.prepare()
            default: break
            }
        }
        prepareCustomEngine()
    }

    func play(_ event: HapticEvent) {
        guard !ending, canPlay() else { return }
        // A new interaction event replaces a still-playing lift/tail, never layers over it.
        if let activePlayer {
            do { try activePlayer.stop(atTime: CHHapticTimeImmediate) }
            catch { logger.debug("Could not stop haptic accent: \(error.localizedDescription, privacy: .public)") }
            self.activePlayer = nil
        }
        if let accent = event.accent(for: strength), ready, let player = players[accent] {
            do {
                try player.start(atTime: CHHapticTimeImmediate)
                activePlayer = player
                return
            } catch {
                logger.debug("Haptic accent unavailable; using native impact: \(error.localizedDescription, privacy: .public)")
            }
        }
        switch event.recipe(for: strength) {
        case let .impact(style, intensity):
            let generator = impact(for: style)
            generator.impactOccurred(intensity: intensity)
            generator.prepare()
        case .selection:
            if selection == nil { selection = UISelectionFeedbackGenerator() }
            selection?.selectionChanged()
            selection?.prepare()
        case .success, .warning, .error:
            if notification == nil { notification = UINotificationFeedbackGenerator() }
            notification?.notificationOccurred(event == .success ? .success : event == .warning ? .warning : .error)
        }
    }

    /// Let the finite seating accent finish before releasing its engine.
    func finish() {
        guard !ending else { return }
        ending = true
        impacts.removeAll()
        selection = nil
        notification = nil
        guard let engine, ready, activePlayer != nil else { cancel(); return }
        engine.notifyWhenPlayersFinished { [weak self] _ in
            Task { @MainActor in self?.cancel() }
            return .leaveEngineRunning
        }
    }

    func cancel() {
        ending = true
        impacts.removeAll()
        selection = nil
        notification = nil
        discardCustomEngine()
        canPlay = { false }
    }

    private func impact(for style: HapticRecipe.Impact) -> UIImpactFeedbackGenerator {
        if let generator = impacts[style] { return generator }
        let generator = UIImpactFeedbackGenerator(style: style.uiStyle)
        impacts[style] = generator
        return generator
    }

    private func prepareCustomEngine() {
        guard strength == .strong, !ending, canPlay(), engine == nil else { return }
        do {
            let engine = try CHHapticEngine()
            let generation = UUID()
            engineGeneration = generation
            self.engine = engine
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = true
            engine.stoppedHandler = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.engineGeneration == generation else { return }
                    // Also invalidate a pending start callback; a late completion
                    // must not make an externally stopped engine look ready.
                    self.discardCustomEngine()
                }
            }
            engine.resetHandler = { [weak self] in
                Task { @MainActor in
                    guard let self, self.engineGeneration == generation else { return }
                    // Players become invalid after a media-server reset. Recreate them only
                    // for this still-eligible gesture; never replay its previous event.
                    self.discardCustomEngine()
                    self.prepareCustomEngine()
                }
            }
            for accent in HapticAccent.allCases {
                players[accent] = try engine.makePlayer(with: accent.makePattern())
            }
            engine.start { [weak self] error in
                Task { @MainActor in
                    guard let self, self.engineGeneration == generation, !self.ending else { return }
                    guard self.canPlay(), error == nil else {
                        self.discardCustomEngine()
                        return
                    }
                    self.ready = true
                }
            }
        } catch {
            logger.debug("Haptic preparation unavailable; native feedback remains active: \(error.localizedDescription, privacy: .public)")
            discardCustomEngine()
        }
    }

    private func discardCustomEngine() {
        engineGeneration = UUID()
        ready = false
        activePlayer = nil
        players.removeAll()
        let previous = engine
        engine = nil
        previous?.stoppedHandler = { _ in }
        previous?.resetHandler = {}
        previous?.stop(completionHandler: nil)
    }
}
