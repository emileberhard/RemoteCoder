import Foundation

enum CaptureResumption: Sendable, Equatable {
    case shouldResume
    case shouldNotResume
    case unknown
}

enum CaptureInterruption: Sendable, Equatable {
    case began
    case ended(CaptureResumption)
    case routeChanged(inputLost: Bool, reasonCode: UInt)
}

@MainActor
protocol CaptureAudioSession: AnyObject {
    var isInputAvailable: Bool { get }
    func startObserving(_ handler: @escaping @MainActor (CaptureInterruption) -> Void)
    func activateForRecording() async throws
    func reactivate() async throws
    func deactivate() async -> Bool
    func preferBuiltInInput(context: String) throws
}
