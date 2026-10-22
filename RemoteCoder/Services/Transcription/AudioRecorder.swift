import Foundation
import AVFoundation
import OSLog

// MARK: - Errors

enum AudioCaptureError: LocalizedError, Sendable {
    case alreadyRecording
    case missingInputFormat
    case invalidInputFormat
    case sessionDidNotDeactivate

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: "A recording is already active."
        case .missingInputFormat: "The microphone's input format was not available."
        case .invalidInputFormat: "The microphone reported an invalid input format."
        case .sessionDidNotDeactivate: "The recording audio session did not release."
        }
    }
}

// MARK: - Recorder

@MainActor
final class AudioRecorder {
    private let logger = Logger(subsystem: "RemoteCoder", category: "VoiceInput.AudioRecorder")
    private let session: any CaptureAudioSession
    private var audioEngine = AVAudioEngine()
    private let levelMeter = AudioLevelMeter()
    private let pcm16Sink = PCM16CaptureSink()

    private var isRecording = false
    private var inputFormat: AVAudioFormat?
    private var meterPeak: Float = 0.015
    private var shouldMaintainRecording = false
    private var pausedForRouteLoss = false
    private var reactivationTask: Task<Void, Never>?
    private var isCaptureRunning = false
    private var isTapInstalled = false

    init(session: any CaptureAudioSession) {
        self.session = session
    }

    func ensurePermission() async throws {
        try await VoiceInputPermissions.requestMicrophoneAccess()
    }

    func activateSession() async throws {
        registerAudioSessionObserversIfNeeded()
        try await session.activateForRecording()
    }

    func deactivateSession() async throws {
        reactivationTask?.cancel()
        reactivationTask = nil
        await stopCapture()
        guard await session.deactivate() else {
            throw AudioCaptureError.sessionDidNotDeactivate
        }
        VoiceModeDiagnostics.log("audio session inactive")
    }

    func start(output: PCM16CaptureOutput) async throws {
        registerAudioSessionObserversIfNeeded()
        guard !isRecording else {
            throw AudioCaptureError.alreadyRecording
        }

        do {
            if isCaptureRunning, audioEngine.isRunning == false {
                VoiceModeDiagnostics.log("capture graph invalidated; rebuilding")
                stopCaptureImmediately()
            }
            if isCaptureRunning == false {
                try await prepareCapture()
            }
            try Task.checkCancellation()
            guard let inputFormat else {
                throw AudioCaptureError.missingInputFormat
            }

            try await pcm16Sink.begin(inputFormat: inputFormat, output: output)
            isRecording = true
            shouldMaintainRecording = true
            pausedForRouteLoss = false
            meterPeak = 0.015

            if audioEngine.isRunning == false {
                audioEngine.prepare()
                try audioEngine.start()
            }
            isCaptureRunning = true
            VoiceModeDiagnostics.log("audio segment sink opened engineRunning=\(audioEngine.isRunning)")
        } catch {
            pcm16Sink.finish()
            isRecording = false
            if isCaptureRunning == false {
                await stopCapture()
            }
            throw error
        }
    }

    func stop() {
        reactivationTask?.cancel()
        reactivationTask = nil
        shouldMaintainRecording = false
        pausedForRouteLoss = false
        pcm16Sink.finish()
        isRecording = false

        stopCaptureImmediately()
        VoiceModeDiagnostics.log("audio segment sink closed")
    }

    func normalizedLevel() -> Float {
        guard isRecording else { return 0 }
        let avgDb = levelMeter.readAveragePowerDecibels()
        let rms = pow(10, avgDb / 20)

        // Adaptive normalization with fast attack and slow decay.
        if rms > meterPeak {
            meterPeak = rms
        } else {
            meterPeak *= 0.995
        }
        meterPeak = max(0.015, min(0.5, meterPeak))

        let normalized = rms / meterPeak
        return min(1.0, sqrt(normalized) * 0.7)
    }

    private func prepareCapture() async throws {
        VoiceModeDiagnostics.log("dictation capture preparation started")
        let inputNode = audioEngine.inputNode
        if inputNode.isVoiceProcessingEnabled {
            try inputNode.setVoiceProcessingEnabled(false)
        }

        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        let format = inputNode.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0,
              hardwareFormat.channelCount > 0,
              format.sampleRate > 0,
              format.channelCount > 0
        else {
            throw AudioCaptureError.invalidInputFormat
        }

        let levelMeter = levelMeter
        let pcm16Sink = pcm16Sink
        try inputNode.installAudioTap(
            onBus: 0,
            bufferSize: 1_024,
            format: format
        ) { readOnlyBuffer, _ in
            let buffer = AVAudioPCMBuffer(copying: readOnlyBuffer)
            levelMeter.process(buffer)
            pcm16Sink.consume(buffer)
        }
        inputFormat = format
        isTapInstalled = true
        VoiceModeDiagnostics.log("capture tap installed sampleRate=\(Int(format.sampleRate)) channels=\(format.channelCount)")
    }

    private func stopCaptureImmediately() {
        pcm16Sink.finish()
        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        audioEngine.stop()
        audioEngine = AVAudioEngine()
        isCaptureRunning = false
        inputFormat = nil
        VoiceModeDiagnostics.log("capture engine stopped")
    }

    private func stopCapture() async {
        stopCaptureImmediately()

        isRecording = false
        shouldMaintainRecording = false
        pausedForRouteLoss = false
        VoiceModeDiagnostics.log("capture pipeline torn down")
    }

    private func registerAudioSessionObserversIfNeeded() {
        session.startObserving { [weak self] interruption in
            self?.handle(interruption)
        }
    }

    private func handle(_ interruption: CaptureInterruption) {
        switch interruption {
        case .began:
            handleAudioSessionInterruption()
        case .ended(let resumption):
            handleAudioSessionResumption(resumption)
        case .routeChanged(let inputLost, let reasonCode):
            handleAudioSessionRouteChange(inputLost: inputLost, reasonCode: reasonCode)
        }
    }

    private func handleAudioSessionInterruption() {
        if shouldMaintainRecording, audioEngine.isRunning {
            audioEngine.pause()
            logger.notice("paused recording due to audio-session interruption")
        }
    }

    private func handleAudioSessionResumption(_ resumption: CaptureResumption) {
        guard shouldMaintainRecording else { return }
        switch resumption {
        case .shouldResume:
            resumeRecordingIfNeeded(context: "interruption ended")
        case .shouldNotResume:
            logger.notice("system recommended leaving the interrupted recording paused")
        case .unknown:
            logger.notice("system provided an unknown audio-session resumption recommendation")
        }
    }

    private func handleAudioSessionRouteChange(inputLost: Bool, reasonCode: UInt) {
        guard shouldMaintainRecording else { return }

        try? session.preferBuiltInInput(context: "route change")

        if inputLost, audioEngine.isRunning {
            audioEngine.pause()
            pausedForRouteLoss = true
            logger.notice("paused recording due to route change: \(reasonCode, privacy: .public)")
        }

        if pausedForRouteLoss, session.isInputAvailable {
            resumeRecordingIfNeeded(context: "route change")
        }
    }

    private func resumeRecordingIfNeeded(context: String) {
        reactivationTask?.cancel()
        reactivationTask = Task { [weak self] in
            await self?.resumeRecording(context: context)
        }
    }

    private func resumeRecording(context: String) async {
        guard shouldMaintainRecording, isCaptureRunning else { return }
        if audioEngine.isRunning {
            pausedForRouteLoss = false
            return
        }

        do {
            try await session.reactivate()
            try Task.checkCancellation()
            guard shouldMaintainRecording, isCaptureRunning else { return }
            try session.preferBuiltInInput(context: context)
            try audioEngine.start()
            pausedForRouteLoss = false
            logger.notice("resumed recording after \(context, privacy: .public)")
        } catch is CancellationError {
            return
        } catch {
            logger.error("failed to reactivate audio session after \(context, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
