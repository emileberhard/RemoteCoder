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
    private let logger = AppLogger(category: "VoiceInput.AudioRecorder")
    private let session: any CaptureAudioSession
    private let engine = CaptureEngine()
    private let levelMeter = AudioLevelMeter()
    private let pcm16Sink = PCM16CaptureSink()

    private var isRecording = false
    private var inputFormat: AVAudioFormat?
    private var shouldMaintainRecording = false
    private var pausedForRouteLoss = false
    private var reactivationTask: Task<Void, Never>?
    private var engineWork: Task<Void, Never>?
    private var isCaptureRunning = false

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
            if isCaptureRunning, await engine.isRunning == false {
                VoiceModeDiagnostics.log("capture graph invalidated; rebuilding")
                stopCaptureImmediately()
            }
            await engineWork?.value
            if isCaptureRunning == false {
                try await prepareCapture()
            }
            try Task.checkCancellation()
            guard let inputFormat else {
                throw AudioCaptureError.missingInputFormat
            }

            try await pcm16Sink.begin(inputFormat: inputFormat, output: output)
            levelMeter.reset()
            isRecording = true
            shouldMaintainRecording = true
            pausedForRouteLoss = false

            try await engine.start()
            isCaptureRunning = true
            VoiceModeDiagnostics.log("audio segment sink opened engineRunning=\(await engine.isRunning)")
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

    func levels() -> AsyncStream<[Float]> {
        levelMeter.levels()
    }

    private func prepareCapture() async throws {
        VoiceModeDiagnostics.log("dictation capture preparation started")
        let format = try await engine.installTap(levelMeter: levelMeter, sink: pcm16Sink)
        inputFormat = format
        VoiceModeDiagnostics.log("capture tap installed sampleRate=\(Int(format.sampleRate)) channels=\(format.channelCount)")
    }

    private func stopCaptureImmediately() {
        pcm16Sink.finish()
        isCaptureRunning = false
        inputFormat = nil
        afterEngineWork { engine in
            await engine.reset()
            VoiceModeDiagnostics.log("capture engine stopped")
        }
    }

    private func stopCapture() async {
        stopCaptureImmediately()
        await engineWork?.value

        isRecording = false
        shouldMaintainRecording = false
        pausedForRouteLoss = false
        VoiceModeDiagnostics.log("capture pipeline torn down")
    }

    private func afterEngineWork(_ operation: @escaping (CaptureEngine) async -> Void) {
        let previous = engineWork
        engineWork = Task { [engine] in
            await previous?.value
            await operation(engine)
        }
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
        guard shouldMaintainRecording else { return }
        afterEngineWork { [logger] engine in
            if await engine.pause() {
                logger.notice("paused recording due to audio-session interruption")
            }
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

        if inputLost, isCaptureRunning {
            pausedForRouteLoss = true
            afterEngineWork { [logger] engine in
                if await engine.pause() {
                    logger.notice("paused recording due to route change: \(reasonCode)")
                }
            }
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
        await engineWork?.value
        if await engine.isRunning {
            pausedForRouteLoss = false
            return
        }

        do {
            try await session.reactivate()
            try Task.checkCancellation()
            guard shouldMaintainRecording, isCaptureRunning else { return }
            try session.preferBuiltInInput(context: context)
            try await engine.resume()
            pausedForRouteLoss = false
            logger.notice("resumed recording after \(context)")
        } catch is CancellationError {
            return
        } catch {
            logger.error("failed to reactivate audio session after \(context): \(error.localizedDescription)")
        }
    }
}

// MARK: - Engine

private actor CaptureEngine {
    private var engine = AVAudioEngine()
    private var isTapInstalled = false

    var isRunning: Bool { engine.isRunning }

    func installTap(levelMeter: AudioLevelMeter, sink: PCM16CaptureSink) throws -> AVAudioFormat {
        let inputNode = engine.inputNode
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

        try inputNode.installAudioTap(
            onBus: 0,
            bufferSize: 1_024,
            format: format
        ) { readOnlyBuffer, _ in
            let buffer = AVAudioPCMBuffer(copying: readOnlyBuffer)
            levelMeter.process(buffer)
            sink.consume(buffer)
        }
        isTapInstalled = true
        return format
    }

    func start() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    func resume() throws {
        try engine.start()
    }

    func pause() -> Bool {
        guard engine.isRunning else { return false }
        engine.pause()
        return true
    }

    func reset() {
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        engine.stop()
        engine = AVAudioEngine()
    }
}
