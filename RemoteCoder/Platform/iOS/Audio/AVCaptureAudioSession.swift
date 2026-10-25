import AVFoundation
import Foundation
import OSLog

@MainActor
final class AVCaptureAudioSession: CaptureAudioSession {
    private let logger = AppLogger(category: "VoiceInput.AudioRecorder")
    private var inactiveObserver: NotificationCenter.ObservationToken?
    private var resumptionObserver: NotificationCenter.ObservationToken?
    private var routeChangeObserver: NSObjectProtocol?

    var isInputAvailable: Bool { AVAudioSession.sharedInstance().isInputAvailable }

    isolated deinit {
        if let routeChangeObserver { NotificationCenter.default.removeObserver(routeChangeObserver) }
    }

    func startObserving(_ handler: @escaping @MainActor (CaptureInterruption) -> Void) {
        if inactiveObserver != nil { return }
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        inactiveObserver = center.addObserver(of: session, for: .didBecomeInactive) { message in
            switch message.deactivationResult {
            case .systemInterruption:
                handler(.began)
            case .appDeactivated:
                break
            @unknown default:
                break
            }
        }

        resumptionObserver = center.addObserver(of: session, for: .resumptionRecommendation) { message in
            switch message.recommendation {
            case .shouldResume:
                handler(.ended(.shouldResume))
            case .shouldNotResume:
                handler(.ended(.shouldNotResume))
            @unknown default:
                handler(.ended(.unknown))
            }
        }

        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { note in
            let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                guard let reasonRaw,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw)
                else {
                    return
                }
                let inputLost = reason == .oldDeviceUnavailable || reason == .noSuitableRouteForCategory
                handler(.routeChanged(inputLost: inputLost, reasonCode: reasonRaw))
            }
        }
    }

    func activateForRecording() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        VoiceModeDiagnostics.log("dictation audio session configured")
        try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try await AudioSessionActivation.activate(session, context: "microphone recording")
        try preferBuiltInInput(context: "activation")
        let input = session.currentRoute.inputs.first?.portType.rawValue ?? "none"
        let output = session.currentRoute.outputs.first?.portType.rawValue ?? "none"
        VoiceModeDiagnostics.log("audio session active input=\(input) output=\(output)")
    }

    func reactivate() async throws {
        try await AudioSessionActivation.activate(AVAudioSession.sharedInstance(), context: "recording resumption")
    }

    func deactivate() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        try? session.setPreferredInput(nil)
        return await AudioSessionActivation.deactivate(session, context: "microphone recording")
    }

    func preferBuiltInInput(context: String) throws {
        let session = AVAudioSession.sharedInstance()
        guard let builtInMic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else {
            logger.notice("built-in microphone unavailable during \(context)")
            return
        }

        try session.setPreferredInput(builtInMic)

        let activeInput = session.currentRoute.inputs.first
        if activeInput?.portType != .builtInMic {
            let activePort = activeInput?.portType.rawValue ?? "none"
            logger.notice("requested built-in microphone during \(context), active input is \(activePort)")
        }
    }
}
