import Foundation
import AVFoundation
import OSLog

// MARK: - Errors

enum AudioCaptureError: LocalizedError, Sendable {
    case alreadyRecording
    case invalidInputFormat
    case sessionDidNotDeactivate

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: "A recording is already active."
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
    private var shouldMaintainRecording = false
    private var pausedForRouteLoss = false
    private var reactivationTask: Task<Void, Never>?
    private var captureWork: Task<Void, Never>?
    private var starting: Task<Void, Error>?
    private var generation = UUID()
    private var isCaptureRunning = false

    init(session: any CaptureAudioSession) {
        self.session = session
    }

    func ensurePermission() async throws {
        try await VoiceInputPermissions.requestMicrophoneAccess()
    }

    func activateSession() async throws {
        registerAudioSessionObserversIfNeeded()
        let previous = captureWork
        let work = Task {
            await previous?.value
            try Task.checkCancellation()
            try await session.activateForRecording()
            try Task.checkCancellation()
        }
        captureWork = Task { _ = await work.result }
        try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    func deactivateSession() async throws {
        stop()
        let previous = captureWork
        let work = Task {
            await previous?.value
            guard await session.deactivate() else {
                throw AudioCaptureError.sessionDidNotDeactivate
            }
            VoiceModeDiagnostics.log("audio session inactive")
        }
        captureWork = Task { _ = await work.result }
        try await work.value
    }

    func start(output: PCM16CaptureOutput) async throws {
        registerAudioSessionObserversIfNeeded()
        guard !isRecording else {
            throw AudioCaptureError.alreadyRecording
        }
        let generation = UUID()
        self.generation = generation
        isRecording = true
        shouldMaintainRecording = true
        pausedForRouteLoss = false
        let previous = captureWork
        let work = Task {
            await previous?.value
            do {
                try Task.checkCancellation()
                VoiceModeDiagnostics.log("dictation capture preparation started")
                let format = try await engine.installTap(levelMeter: levelMeter, sink: pcm16Sink)
                try Task.checkCancellation()
                VoiceModeDiagnostics.log("capture tap installed sampleRate=\(Int(format.sampleRate)) channels=\(format.channelCount)")
                try await pcm16Sink.begin(inputFormat: format, output: output)
                try Task.checkCancellation()
                levelMeter.reset()
                try await engine.start()
                try Task.checkCancellation()
                isCaptureRunning = true
                VoiceModeDiagnostics.log("audio segment sink opened")
            } catch {
                pcm16Sink.finish()
                await engine.reset()
                if self.generation == generation {
                    isRecording = false
                    shouldMaintainRecording = false
                    isCaptureRunning = false
                }
                throw error
            }
        }
        starting = work
        captureWork = Task { _ = await work.result }
        defer {
            if self.generation == generation { starting = nil }
        }
        try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    func stop() {
        generation = UUID()
        starting?.cancel()
        starting = nil
        reactivationTask?.cancel()
        reactivationTask = nil
        shouldMaintainRecording = false
        pausedForRouteLoss = false
        pcm16Sink.finish()
        isRecording = false
        isCaptureRunning = false
        afterCaptureWork { engine in
            await engine.reset()
            VoiceModeDiagnostics.log("capture engine stopped")
        }
        VoiceModeDiagnostics.log("audio segment sink closed")
    }

    func levels() -> AsyncStream<[Float]> {
        levelMeter.levels()
    }

    private func afterCaptureWork(_ operation: @escaping (CaptureEngine) async -> Void) {
        let previous = captureWork
        captureWork = Task { [engine] in
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
        reactivationTask?.cancel()
        afterCaptureWork { [logger] engine in
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
            reactivationTask?.cancel()
            logger.notice("system recommended leaving the interrupted recording paused")
        case .unknown:
            logger.notice("system provided an unknown audio-session resumption recommendation")
        }
    }

    private func handleAudioSessionRouteChange(inputLost: Bool, reasonCode: UInt) {
        guard shouldMaintainRecording else { return }

        try? session.preferBuiltInInput(context: "route change")

        if inputLost {
            reactivationTask?.cancel()
            pausedForRouteLoss = true
            afterCaptureWork { [logger] engine in
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
        let previous = captureWork
        let work = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, shouldMaintainRecording, isCaptureRunning else { return }
            await resumeRecording(context: context)
        }
        reactivationTask = work
        captureWork = work
    }

    private func resumeRecording(context: String) async {
        do {
            try Task.checkCancellation()
            let running = await engine.isRunning
            try Task.checkCancellation()
            if running {
                pausedForRouteLoss = false
                return
            }
            try Task.checkCancellation()
            try await session.reactivate()
            try Task.checkCancellation()
            guard shouldMaintainRecording, isCaptureRunning else { return }
            try session.preferBuiltInInput(context: context)
            try await engine.resume()
            try Task.checkCancellation()
            pausedForRouteLoss = false
            logger.notice("resumed recording after \(context)")
        } catch is CancellationError {
            return
        } catch {
            logger.error("failed to reactivate audio session after \(context): \(error.localizedDescription)")
        }
    }
}

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
        try Task.checkCancellation()
        guard !engine.isRunning else { return }
        engine.prepare()
        try Task.checkCancellation()
        try engine.start()
    }

    func resume() throws {
        try Task.checkCancellation()
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
