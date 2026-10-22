#if os(macOS)
@MainActor
final class ForegroundOnlyBackgroundExecution: BackgroundExecution {
    func hold(named name: String, onExpiration: @escaping @MainActor () -> Void) {}

    func holdWithGrace(named name: String, for grace: Duration, onExpiration: @escaping @MainActor () -> Void) {}

    func release() {}
}
#endif
