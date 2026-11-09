import Foundation
@testable import RemoteCoder

@MainActor
final class HapticFixture {
    var active = true
    var callActive = false
    let native = RecordingNativeHapticPlayer()
    var players: [RecordingHapticPlayer] = []
    lazy var service = makeService()

    func makeService(supportsHaptics: Bool = true) -> HapticService {
        let service = HapticService(supportsHaptics: supportsHaptics,
                                    isActive: { [weak self] in self?.active == true },
                                    makeInteractionPlayer: { [weak self] _ in
                                        let player = RecordingHapticPlayer()
                                        self?.players.append(player)
                                        return player
                                    }, makeStreamingPlayer: { SilentStreamingHapticPlayer() })
        service.attach(native)
        service.bindCallState { [weak self] in self?.callActive == true }
        return service
    }

    func cleanUp() {
        service.cancelPlayback()
    }
}

@MainActor
final class RecordingHapticPlayer: HapticInteractionPlaying {
    var hasActiveAccent = false
    var events: [HapticEvent] = []
    var finished = false
    var cancelled = false
    var isEligible: @MainActor () -> Bool = { false }

    func prepare(canPlay: @escaping @MainActor () -> Bool) { isEligible = canPlay }
    func play(_ event: HapticEvent) { events.append(event) }
    func finish() { finished = true }
    func cancel() { cancelled = true; hasActiveAccent = false }
}

@MainActor
final class SilentStreamingHapticPlayer: HapticStreamingPlaying {
    func prepare(canPlay: @escaping @MainActor () -> Bool) {}
    func play(punch: Float) {}
    func cancel() {}
}

@MainActor
final class RecordingNativeHapticPlayer: HapticNativePlaying {
    var events: [HapticRecipe] = []

    func prepare(_ recipe: HapticRecipe) {}
    func play(_ event: HapticEvent) { events.append(event.recipe) }
    func release() {}
}
