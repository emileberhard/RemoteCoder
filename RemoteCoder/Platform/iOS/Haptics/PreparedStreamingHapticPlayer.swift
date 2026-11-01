import CoreHaptics
import Foundation
import OSLog

@MainActor
final class PreparedStreamingHapticPlayer: HapticStreamingPlaying {
    private enum State { case stopped, starting, ready }
    private var engine: CHHapticEngine?
    private var player: (any CHHapticPatternPlayer)?
    private var state = State.stopped
    private var generation = UUID()
    private var canPlay: @MainActor () -> Bool = { false }
    private let logger = AppLogger(category: "Haptics")
    private let signposter = OSSignposter(subsystem: AppLogger.subsystem, category: "Haptics")

    func prepare(canPlay: @escaping @MainActor () -> Bool) {
        self.canPlay = canPlay
        guard state == .stopped, canPlay() else { return }
        do {
            let engine = try self.engine ?? CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = true
            self.engine = engine
            let generation = generation
            engine.stoppedHandler = { [weak self] reason in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    if reason == .idleTimeout {
                        self.state = .stopped
                        self.player = nil
                    } else {
                        self.discardEngine()
                    }
                }
            }
            engine.resetHandler = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    let canPlay = self.canPlay
                    self.discardEngine()
                    if canPlay() { self.prepare(canPlay: canPlay) }
                }
            }
            state = .starting
            signposter.emitEvent("streaming-engine-start")
            engine.start { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    guard error == nil, self.canPlay() else {
                        if let error { self.logger.notice("Streaming haptic start failed: \(error.localizedDescription)") }
                        self.cancel()
                        return
                    }
                    self.state = .ready
                    self.signposter.emitEvent("streaming-engine-ready")
                }
            }
        } catch {
            logger.notice("Streaming haptic preparation failed: \(error.localizedDescription)")
            cancel()
        }
    }

    func play(punch: Float) {
        guard state == .ready, canPlay(), let engine else {
            signposter.emitEvent("streaming-word-dropped")
            return
        }
        do {
            let player = try engine.makePlayer(with: Self.pattern(punch: punch))
            try player.start(atTime: CHHapticTimeImmediate)
            self.player = player
            signposter.emitEvent("streaming-word-played", "punch=\(punch)")
        } catch {
            logger.notice("Streaming haptic playback failed: \(error.localizedDescription)")
            cancel()
        }
    }

    static func pattern(punch: Float) throws -> CHHapticPattern {
        let recipe = StreamingHapticRecipe(punch: punch, variation: .random(in: StreamingHapticRecipe.sharpnessVariation))
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: recipe.intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: recipe.sharpness),
        ], relativeTime: 0)
        return try CHHapticPattern(events: [event], parameters: [])
    }

    func cancel() {
        canPlay = { false }
        discardEngine()
    }

    private func discardEngine() {
        generation = UUID()
        state = .stopped
        player = nil
        let engine = engine
        self.engine = nil
        engine?.stoppedHandler = { _ in }
        engine?.resetHandler = {}
        engine?.stop(completionHandler: nil)
    }
}
