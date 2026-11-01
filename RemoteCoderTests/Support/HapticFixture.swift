import Foundation
@testable import RemoteCoder

@MainActor
final class HapticFixture {
    let suite = "RemoteCoderTests.Haptics.\(UUID())"
    let defaults: UserDefaults
    var active = true
    var callActive = false
    let native = RecordingNativeHapticPlayer()
    var players: [RecordingHapticPlayer] = []
    var streamingPlayers: [RecordingStreamingHapticPlayer] = []
    lazy var service = makeService()

    init() {
        guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("Test defaults unavailable") }
        self.defaults = defaults
    }

    func makeService(supportsHaptics: Bool = true) -> HapticService {
        let service = HapticService(defaults: defaults, supportsHaptics: supportsHaptics,
                                    isActive: { [weak self] in self?.active == true },
                                    makeInteractionPlayer: { [weak self] _ in
                                        let player = RecordingHapticPlayer()
                                        self?.players.append(player)
                                        return player
                                    }, makeStreamingPlayer: { [weak self] in
                                        let player = RecordingStreamingHapticPlayer()
                                        self?.streamingPlayers.append(player)
                                        return player
                                    })
        service.attach(native)
        service.bindCallState { [weak self] in self?.callActive == true }
        return service
    }

    func cleanUp() {
        service.cancelPlayback()
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
final class RecordingHapticPlayer: HapticInteractionPlaying {
    var hasActiveAccent = false
    var events: [HapticEvent] = []
    var finished = false
    var cancelled = false
    var isEligible: @MainActor () -> Bool = { false }

    func prepare(strength: HapticStrength, canPlay: @escaping @MainActor () -> Bool) { isEligible = canPlay }
    func play(_ event: HapticEvent) { events.append(event) }
    func finish() { finished = true }
    func cancel() { cancelled = true; hasActiveAccent = false }
}

@MainActor
final class RecordingStreamingHapticPlayer: HapticStreamingPlaying {
    var punches: [Float] = []
    var cancelled = false
    var isEligible: @MainActor () -> Bool = { false }

    func prepare(canPlay: @escaping @MainActor () -> Bool) { isEligible = canPlay }
    func play(punch: Float) { punches.append(punch) }
    func cancel() { cancelled = true }
}


@MainActor
final class RecordingNativeHapticPlayer: HapticNativePlaying {
    var events: [HapticRecipe] = []
    var prepared: [HapticRecipe] = []
    var releases = 0

    func prepare(_ recipe: HapticRecipe) { prepared.append(recipe) }
    func play(_ recipe: HapticRecipe) { events.append(recipe) }
    func release() { releases += 1 }
}
