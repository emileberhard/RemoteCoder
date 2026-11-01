@MainActor
protocol HapticInteractionPlaying: AnyObject {
    var hasActiveAccent: Bool { get }
    func prepare(strength: HapticStrength, canPlay: @escaping @MainActor () -> Bool)
    func play(_ event: HapticEvent)
    func finish()
    func cancel()
}
