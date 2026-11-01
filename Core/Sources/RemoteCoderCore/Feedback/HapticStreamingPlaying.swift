@MainActor
protocol HapticStreamingPlaying: AnyObject {
    func prepare(canPlay: @escaping @MainActor () -> Bool)
    func play(punch: Float)
    func cancel()
}
