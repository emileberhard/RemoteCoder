#if os(macOS)
import AVFoundation

@MainActor
final class AVCaptureAudioSession: CaptureAudioSession {
    var isInputAvailable: Bool {
        AVCaptureDevice.default(for: .audio) != nil
    }

    func startObserving(_ handler: @escaping @MainActor (CaptureInterruption) -> Void) {}

    func activateForRecording() async throws {}

    func reactivate() async throws {}

    func deactivate() async -> Bool { true }

    func preferBuiltInInput(context: String) throws {}
}
#endif
