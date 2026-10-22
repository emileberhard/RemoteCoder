@MainActor
protocol HapticInteractionPlaying: AnyObject {
    func prepare(strength: HapticStrength, canPlay: @escaping @MainActor () -> Bool)
    func play(_ event: HapticEvent)
    func finish()
    func cancel()
}
