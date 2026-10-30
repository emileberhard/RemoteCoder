import Foundation
import OSLog
import Observation
import SpeechKit
import DictationLibrary

// MARK: - Voice Input Controller (Recording + Transcribe Orchestration)

/// The microphone side of dictation. Injectable so audio ownership — who records,
/// who stops, whose draft the text lands in — can be tested without touching
/// `AVAudioSession`.
@MainActor
protocol VoiceInputRecording: AnyObject {
    func ensurePermission() async throws
    func activateSession() async throws
    func deactivateSession() async throws
    func start(output: PCM16CaptureOutput) async throws
    func stop()
    func levels() -> AsyncStream<[Float]>
}

extension AudioRecorder: VoiceInputRecording {}

@MainActor
@Observable
final class VoiceInputController {
    private struct LiveTranscription {
        let dictation: RealtimeDictation
        let provider: GatewaySpeechProvider
    }

    private struct ActiveDictation {
        let writer: DictationRecordingWriter<ExecutionTarget>
        let live: LiveTranscription?
        let configuration: TranscriptionConfiguration
        let archive: SharedDictationLibrary.Capture?
    }

    private enum SavedAudio {
        case complete(DictationRecording<ExecutionTarget>)
        case partial(DictationRecording<ExecutionTarget>, any Error)
        case unsaved(any Error)

        var recording: DictationRecording<ExecutionTarget>? {
            switch self {
            case .complete(let recording), .partial(let recording, _): recording
            case .unsaved: nil
            }
        }
    }

    private struct StoppedDictation {
        let recordingID: UUID
        let audio: SavedAudio
        let live: LiveTranscription?
        let configuration: TranscriptionConfiguration
        let archive: SharedDictationLibrary.Capture?
    }

    private let access: GatewaySpeechAccess
    private let owner: ExecutionTarget
    private let transcriber: TranscriptionService
    private let configuration: @MainActor () -> TranscriptionConfiguration
    private let recorder: any VoiceInputRecording
    private let recordings: DictationRecordingStore<ExecutionTarget>
    private let haptics: HapticService
    let library: SharedDictationLibrary?
    private let captureOwner = UUID()
    private let logger = AppLogger(category: "VoiceInput")

    private(set) var isRecording = false
    private(set) var isTranscribing = false
    private(set) var recordingStartTime: Date?

    @ObservationIgnored private var acceptsCapture = true
    @ObservationIgnored private var captureAccountMonitor: Task<Void, Never>?
    @ObservationIgnored private var starting: Task<Void, any Error>?
    @ObservationIgnored private var stopping: Task<Void, any Error>?
    @ObservationIgnored private var recordingSaveFailure: (any Error)?
    @ObservationIgnored private var active: ActiveDictation?
    @ObservationIgnored private var stopped: StoppedDictation?
    @ObservationIgnored private var inFlightRecordingID: UUID?

    init(
        access: GatewaySpeechAccess,
        owner: ExecutionTarget,
        transcriber: TranscriptionService,
        recorder: any VoiceInputRecording = AudioRecorder(session: AVCaptureAudioSession()),
        recordings: DictationRecordingStore<ExecutionTarget> = .app,
        haptics: HapticService = .shared,
        library: SharedDictationLibrary? = nil,
        configuration: @escaping @MainActor () -> TranscriptionConfiguration = { .current() }
    ) {
        self.configuration = configuration
        self.access = access
        self.owner = owner
        self.haptics = haptics
        self.library = library
        self.transcriber = transcriber
        self.recorder = recorder
        self.recordings = recordings
    }

    func markRecordingRequested() {
        guard acceptsCapture else { return }
        isRecording = true
    }

    func markStopRequested() {
        isRecording = false
        isTranscribing = true
    }

    func markTranscriptionEnded() {
        isTranscribing = false
    }

    /// Start recording assuming `markRecordingRequested()` was already called by the caller.
    func startAsync() async throws {
        guard acceptsCapture else { throw CancellationError() }
        let start = Task { try await openCapture() }
        starting = start
        defer { starting = nil }
        try await start.value
    }

    private func openCapture() async throws {
        VoiceModeDiagnostics.log("recording start requested source=composer")
        do {
            try await recorder.ensurePermission()
            try Task.checkCancellation()
            haptics.beginCapture(owner: captureOwner)
            try await recorder.activateSession()
            try Task.checkCancellation()
            try await startRecording()
            recordingStartTime = Date()
            VoiceModeDiagnostics.log("recording started source=composer")
        } catch {
            captureAccountMonitor?.cancel()
            captureAccountMonitor = nil
            isRecording = false
            recordingStartTime = nil
            try? await recorder.deactivateSession()
            haptics.endCapture(owner: captureOwner)
            VoiceModeDiagnostics.log("recording start failed source=composer error=\(error.localizedDescription)")
            throw error
        }
    }

    func stopRecording(onCaptureEnded: (() -> Void)? = nil) async throws {
        if let stopping { try await stopping.value; return }
        let task = Task { try await stopCapture(onCaptureEnded: onCaptureEnded) }
        stopping = task
        defer { stopping = nil }
        try await task.value
    }

    private func stopCapture(onCaptureEnded: (() -> Void)?) async throws {
        VoiceModeDiagnostics.log("recording stop requested")
        if let starting {
            starting.cancel()
            _ = await starting.result
            guard active != nil else { throw CancellationError() }
        }
        recorder.stop()
        guard let active else {
            // Stopping without a recording must still stop capture and release its
            // haptic suppression; otherwise every later control stays silent.
            try? await recorder.deactivateSession()
            haptics.endCapture(owner: captureOwner)
            isRecording = false
            recordingStartTime = nil
            throw DictationError.noActiveRecording
        }
        self.active = nil
        if let archive = active.archive { library?.finish(archive) }
        let audio = await Self.finish(active.writer)
        switch audio {
        case .complete: break
        case .partial(_, let error), .unsaved(let error): recordingSaveFailure = error
        }
        let released: Bool
        do { try await recorder.deactivateSession(); released = true }
        catch {
            released = false
            logger.error("Capture stopped but audio session release failed: \(error.localizedDescription)")
        }
        // The capture graph has stopped even if the session release failed. Keep
        // transcribing the retained recording, but do not promise a tactile stop.
        haptics.endCapture(owner: captureOwner)
        if released { onCaptureEnded?() }
        isRecording = false
        recordingStartTime = nil
        stopped = StoppedDictation(recordingID: active.writer.id, audio: audio, live: active.live, configuration: active.configuration, archive: active.archive)
        VoiceModeDiagnostics.log("recording segment stopped")
    }

    func beginQuiescing() {
        acceptsCapture = false
        starting?.cancel()
    }

    func quiesceForTermination() async throws {
        defer { captureAccountMonitor?.cancel(); captureAccountMonitor = nil }
        beginQuiescing()
        _ = await starting?.result
        if active != nil || stopping != nil { try await stopRecording() }
        if let stopped {
            await stopped.live?.dictation.cancel()
            self.stopped = nil
            inFlightRecordingID = nil
            isTranscribing = false
            switch stopped.audio {
            case .complete: break
            case .partial(_, let error), .unsaved(let error): throw DictationError.recordingNotSaved(error)
            }
        }
        await library?.finishPendingCaptures()
        if let recordingSaveFailure { throw DictationError.recordingNotSaved(recordingSaveFailure) }
    }

    func resumeAfterTermination() { acceptsCapture = true }

    func transcribe() async throws -> Dictation {
        guard let stopped else { throw DictationError.noStoppedRecording }
        self.stopped = nil
        isTranscribing = true
        defer {
            isTranscribing = false
            if inFlightRecordingID == stopped.recordingID { inFlightRecordingID = nil }
        }
        defer { captureAccountMonitor?.cancel(); captureAccountMonitor = nil }
        do {
            return try await withAccount(stopped.archive?.account) { [self] in try await transcribe(stopped) }
        } catch {
            await stopped.live?.dictation.cancel()
            if let archive = stopped.archive, archive.writer != nil {
                await library?.failure(recordingID: stopped.recordingID, plan: archive.plan, error: error)
            }
            throw error
        }
    }

    private func transcribe(_ stopped: StoppedDictation) async throws -> Dictation {
        VoiceModeDiagnostics.log("transcription started")
        if let live = stopped.live {
            do {
                let raw = try await live.dictation.finish()
                let text = try await archiveResult(raw, recordingID: stopped.recordingID, plan: stopped.archive?.plan, account: stopped.archive?.account, model: stopped.configuration.model.libraryID)
                VoiceModeDiagnostics.log("transcription completed characters=\(text.count)")
                return Dictation(text: text, recordingID: stopped.recordingID, recording: stopped.audio.recording)
            } catch let error as RealtimeDictationError {
                let explained = access.explain(error, provider: live.provider)
                VoiceModeDiagnostics.log("realtime transcription failed; transcribing the saved recording error=\(explained.localizedDescription)")
            }
        }
        let recording: DictationRecording<ExecutionTarget>
        switch stopped.audio {
        case .complete(let saved): recording = saved
        case .partial(_, let error), .unsaved(let error): throw DictationError.recordingNotSaved(error)
        }
        let raw = try await transcribe(recording, configuration: stopped.configuration)
        let text = try await archiveResult(raw, recordingID: recording.id, plan: stopped.archive?.plan, account: stopped.archive?.account, model: stopped.configuration.model.batchLibraryID)
        return Dictation(text: text, recordingID: recording.id, recording: recording)
    }

    /// Archived recordings retain their frozen plan; older recovery recordings
    /// use the current local settings.
    func transcribe(_ recording: DictationRecording<ExecutionTarget>) async throws -> String {
        let local = configuration()
        let resolved = try await library?.plan(for: recording.id)
        let configuration = try resolved.map { try TranscriptionConfiguration(plan: $0.plan, local: local) } ?? local
        return try await withAccount(resolved?.account) { [self] in
            let raw = try await transcribe(recording, configuration: configuration)
            return try await archiveResult(raw, recordingID: recording.id, plan: resolved?.plan, account: resolved?.account, model: configuration.model.batchLibraryID)
        }
    }

    private func transcribe(_ recording: DictationRecording<ExecutionTarget>, configuration: TranscriptionConfiguration) async throws -> String {
        do {
            let text = try await transcriber.transcribe(recording, configuration: configuration)
            VoiceModeDiagnostics.log("transcription completed characters=\(text.count)")
            return text
        } catch RemoteCoderTranscriptionService.ServiceError.emptyResponse {
            VoiceModeDiagnostics.log("transcription completed characters=0")
            return ""
        } catch {
            VoiceModeDiagnostics.log("transcription failed error=\(error.localizedDescription)")
            throw error
        }
    }

    func savedRecordings() async throws -> [DictationRecording<ExecutionTarget>] {
        let listed = try await recordings.recordings()
        return listed.filter { $0.owner == owner && $0.id != inFlightRecordingID }
    }

    func discard(_ recording: DictationRecording<ExecutionTarget>) async {
        do {
            try await recordings.discard(recording)
        } catch {
            logger.error("saved dictation could not be discarded: \(error.localizedDescription)")
        }
    }

    func levels() -> AsyncStream<[Float]> {
        recorder.levels()
    }

    private func startRecording() async throws {
        let local = configuration()
        let archive = try await library?.prepare(configuration: local)
        var recoveryWriter: DictationRecordingWriter<ExecutionTarget>?
        var liveDictation: RealtimeDictation?
        do {
            captureAccountMonitor?.cancel()
            captureAccountMonitor = nil
            if let archive, let account = archive.account, let library {
                let events = try await library.accountEvents(validating: account)
                captureAccountMonitor = Task { [weak self] in
                    for await session in events {
                        guard !Task.isCancelled else { return }
                        guard session == account else {
                            await self?.captureAccountChanged(id: archive.id)
                            return
                        }
                    }
                }
            }
            let configuration = try archive.map { try TranscriptionConfiguration(plan: $0.plan, local: local) } ?? local
            let realtime = try await transcriber.makeRealtimeTranscription(configuration: configuration)
            if let account = archive?.account { try await library?.validateAccount(account) }
            try Task.checkCancellation()
            let sampleRate = realtime?.session.sampleRate ?? TranscriptionCapture.batchSampleRate
            let live = realtime.map { LiveTranscription(dictation: RealtimeDictation(session: $0.session), provider: $0.provider) }
            let dictation = live?.dictation
            liveDictation = dictation
            let writer: DictationRecordingWriter<ExecutionTarget>
            if let archive {
                writer = try await recordings.startRecording(id: archive.id, owner: owner, sampleRate: sampleRate)
            } else {
                writer = try await recordings.startRecording(owner: owner, sampleRate: sampleRate)
            }
            recoveryWriter = writer
            try Task.checkCancellation()
            var output = PCM16CaptureOutput(sampleRate: sampleRate) { chunk in
                writer.append(chunk)
                dictation?.append(chunk)
            }
            if let original = archive?.writer {
                output.configureOriginal = { try original.configure(format: $0) }
                output.receiveOriginal = { original.append($0) }
            }
            try await recorder.start(output: output)
            if let account = archive?.account { try await library?.validateAccount(account) }
            active = ActiveDictation(writer: writer, live: live, configuration: configuration, archive: archive)
            inFlightRecordingID = writer.id
        } catch {
            recorder.stop()
            await liveDictation?.cancel()
            if let recoveryWriter { await recordings.closeAfterFailedStart(recoveryWriter) }
            if let archive { library?.finish(archive) }
            captureAccountMonitor?.cancel()
            captureAccountMonitor = nil
            throw error
        }
    }

    private func captureAccountChanged(id: UUID) async {
        starting?.cancel()
        if active?.writer.id == id {
            let live = active?.live
            do { try await stopRecording() }
            catch { logger.error("account-change capture stop failed: \(error.localizedDescription)") }
            await live?.dictation.cancel()
        }
        if stopped?.recordingID == id {
            await stopped?.live?.dictation.cancel()
            stopped = nil
        }
        if inFlightRecordingID == id { inFlightRecordingID = nil }
        isTranscribing = false
        library?.accountChanged()
    }

    private func withAccount<Value: Sendable>(_ account: DictationAccountSession?,
        operation: @escaping @MainActor @Sendable () async throws -> Value) async throws -> Value {
        guard let account, let library else { return try await operation() }
        let events = try await library.accountEvents(validating: account)
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                for await session in events {
                    try Task.checkCancellation()
                    if session != account { throw DictationLibraryError.accountChanged }
                }
                throw CancellationError()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    private func archiveResult(_ text: String, recordingID: UUID, plan: DictationLibrary.DictationPlan?, account: DictationAccountSession?, model: String) async throws -> String {
        guard let plan, let library else { return text }
        return try await library.result(text, recordingID: recordingID, plan: plan, account: account, model: model, access: access)
    }

    private static func finish(_ writer: DictationRecordingWriter<ExecutionTarget>) async -> SavedAudio {
        do {
            return .complete(try await writer.finish())
        } catch let incomplete as IncompleteDictationRecording<ExecutionTarget> {
            return .partial(incomplete.recording, incomplete.cause)
        } catch {
            return .unsaved(error)
        }
    }
}
