#if os(macOS)
import AppKit

extension HapticService {
    static let shared = HapticService(
        defaults: AppStorageScope.current.defaults,
        supportsHaptics: false,
        isActive: { NSApplication.shared.isActive },
        makeInteractionPlayer: { _ in NoHapticPlayer() },
        makeStreamingPlayer: { NoHapticPlayer() }
    )

    func copy(_ text: String) {
        Pasteboard.copy(text)
        play(.copied)
    }
}

@MainActor
final class NoHapticPlayer: HapticInteractionPlaying, HapticStreamingPlaying {
    var hasActiveAccent: Bool { false }
    func prepare(strength: HapticStrength, canPlay: @escaping @MainActor () -> Bool) {}
    func play(_ event: HapticEvent) {}
    func finish() {}
    func cancel() {}
    func prepare(canPlay: @escaping @MainActor () -> Bool) {}
    func play(punch: Float) {}
}
#endif
