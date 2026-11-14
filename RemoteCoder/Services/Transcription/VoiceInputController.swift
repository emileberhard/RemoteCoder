import Foundation
import OSLog
import Observation
import SpeechKit
import DictationLibrary
import SpeakerRecognition

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
        let progressive: ProgressiveRealtimeTranscriptionSession?
    }

    private struct ActiveDictation {
        let writer: DictationRecordingWriter<ExecutionTarget>
        let live: LiveTranscription?
        let configuration: TranscriptionConfiguration
        let archive: SharedDictationLibrary.Capture?
        let recognition: DictationVoiceSession
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
        let stopRequested: ContinuousClock.Instant
        let recognition: DictationVoiceSession
    }

    private let access: GatewaySpeechAccess
    private let owner: ExecutionTarget
    private let transcriber: TranscriptionService
    private let configuration: @MainActor () -> TranscriptionConfiguration
    private let recorder: any VoiceInputRecording
    private let recordings: DictationRecordingStore<ExecutionTarget>
    private let haptics: HapticService
    let library: SharedDictationLibrary?
    private let voices: DictationVoiceProfiles
    private let captureOwner = UUID()
    private let logger = AppLogger(category: "VoiceInput")

    private(set) var failedTranscription: (id: UUID, message: String)?
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
        voices: DictationVoiceProfiles,
        configuration: @escaping @MainActor () -> TranscriptionConfiguration = { .current() }
    ) {
        self.configuration = configuration
        self.access = access
        self.owner = owner
        self.haptics = haptics
        self.library = library
        self.voices = voices
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
        let stopRequested = ContinuousClock.now
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
        if active.recognition.isActive {
            let recognition = active.recognition
            let transcriber = transcriber
            let configuration = active.configuration
            await recognition.finish { pcm, uploaded in
                try await transcriber.speakerPhrases(pcm, configuration: configuration, uploadFinished: uploaded)
            }
        }
        if let archive = active.archive { library?.finish(archive) }
        let audio = await Self.finish(active.writer)
        switch audio {
        case .complete: break
        case .partial(_, let error), .unsaved(let error): recordingSaveFailure = error
        }
        active.live?.dictation.endInput()
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
        stopped = StoppedDictation(recordingID: active.writer.id, audio: audio, live: active.live, configuration: active.configuration,
                                   archive: active.archive, stopRequested: stopRequested,
                                   recognition: active.recognition)
        await recordAttempt(recordingID: active.writer.id, audio: audio, live: active.live, outcome: "stopped")
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
        await active?.live?.dictation.cancel()
        await active?.recognition.cancel()
        if active != nil || stopping != nil { try await stopRecording() }
        if let stopped {
            await stopped.live?.dictation.cancel()
            await stopped.recognition.cancel()
            self.stopped = nil
            inFlightRecordingID = nil
            isTranscribing = false
            switch stopped.audio {
            case .complete: break
            case .partial(_, let error), .unsaved(let error): throw DictationError.recordingNotSaved(error)
            }
        }
        await library?.finishArchiving()
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
            let result = try await withAccount(stopped.archive?.account) { [self] in try await transcribe(stopped) }
            if failedTranscription?.id == stopped.recordingID { failedTranscription = nil }
            await recordAttempt(recordingID: stopped.recordingID, audio: stopped.audio, live: stopped.live, outcome: "text")
            return result
        } catch {
            if !(error is CancellationError) {
                failedTranscription = (stopped.recordingID, error.localizedDescription)
                logger.error("dictation failed id=\(stopped.recordingID) error=\(error.localizedDescription)")
            }
            await recordAttempt(recordingID: stopped.recordingID, audio: stopped.audio, live: stopped.live,
                                outcome: error is CancellationError ? "cancelled" : "failed")
            await stopped.live?.dictation.cancel()
            await stopped.recognition.cancel()
            if let archive = stopped.archive, archive.writer != nil {
                library?.failure(recordingID: stopped.recordingID, plan: archive.plan, error: error)
            }
            throw error
        }
    }

    private func transcribe(_ stopped: StoppedDictation) async throws -> Dictation {
        VoiceModeDiagnostics.log("transcription started")
        if let live = stopped.live {
            do {
                let raw = try await live.dictation.finish()
                let model = stopped.configuration.model.libraryID
                let result = try await resolveVoices(DictationTranscript(text: raw, model: model), stopped: stopped)
                let transcript = try await archiveResult(result, recordingID: stopped.recordingID, plan: stopped.archive?.plan)
                Self.logTranscribed(stopped, route: "realtime", model: transcript.model, characters: transcript.text.count)
                return Dictation(transcript: transcript, recordingID: stopped.recordingID, recording: stopped.audio.recording)
            } catch let error as RealtimeDictationError {
                let explained = access.explain(error, provider: live.provider)
                VoiceModeDiagnostics.log("realtime transcription failed; transcribing the saved recording id=\(stopped.recordingID) error=\(explained.localizedDescription)")
                await recordAttempt(recordingID: stopped.recordingID, audio: stopped.audio, live: stopped.live, outcome: "fallback")
            }
        }
        let route: StaticString = stopped.live == nil ? "saved" : "fallback"
        let recording: DictationRecording<ExecutionTarget>
        switch stopped.audio {
        case .complete(let saved): recording = saved
        case .partial(_, let error), .unsaved(let error): throw DictationError.recordingNotSaved(error)
        }
        let raw = try await transcribe(recording, configuration: stopped.configuration)
        let result = try await resolveVoices(raw, stopped: stopped)
        let transcript = try await archiveResult(result, recordingID: recording.id, plan: stopped.archive?.plan)
        Self.logTranscribed(stopped, route: route, model: transcript.model, characters: transcript.text.count)
        return Dictation(transcript: transcript, recordingID: recording.id, recording: recording)
    }

    private func resolveVoices(_ original: DictationTranscript, stopped: StoppedDictation) async throws -> DictationTranscript {
        let recognition = stopped.recognition
        do {
            let result = try await recognition.resolve(original)
            switch result.check {
            case .success(let check): voices.checked(check, hostID: owner.hostID)
            case .failure(let error): voices.failed(error, stage: .filter, hostID: owner.hostID)
            case nil: return result.transcript
            }
            let upload = result.upload.map { String(Self.milliseconds($0)) } ?? "unknown"
            let check = try? result.check?.get()
            let completion = check?.labelledReplyTime.map { String(Self.milliseconds($0)) } ?? "unknown"
            let trigger = check?.labelRequest?.rawValue ?? "none"
            VoiceModeDiagnostics.log("dictation voice check outcome=\(result.transcript.outcome?.path.rawValue ?? "unknown") labels_trigger=\(trigger) upload_ms=\(upload) labelled_reply_ms=\(completion) added_wait_ms=\(Self.milliseconds(result.wait))")
            await recognition.cancel()
            return result.transcript
        } catch is CancellationError where !Task.isCancelled {
            await recognition.cancel()
            return original
        } catch {
            await recognition.cancel()
            throw error
        }
    }

    private func recordAttempt(recordingID: UUID, audio: SavedAudio, live: LiveTranscription?, outcome: String) async {
        let origin = access.host.gatewayHTTPBaseURL().map {
            "\($0.scheme ?? "unknown")://\($0.host() ?? "unknown"):\($0.port ?? 443)"
        } ?? "unknown"
        let duration = audio.recording.map { String(Self.milliseconds($0.duration)) } ?? "unknown"
        let sentBytes = await live?.progressive?.uploadedBodyByteCount
        let sent = sentBytes.map(String.init) ?? "unknown"
        logger.notice("dictation attempt id=\(recordingID) configured_origin=\(origin) audio_ms=\(duration) live_body_bytes_sent=\(sent) outcome=\(outcome)")
        Task { await DiagnosticsOutbox.shared.persistPending() }
    }

    private static func logTranscribed(_ stopped: StoppedDictation, route: StaticString, model: String, characters: Int) {
        let stopToText = ContinuousClock.now - stopped.stopRequested
        let audio = stopped.audio.recording.map { "\(milliseconds($0.duration))" } ?? "unknown"
        VoiceModeDiagnostics.log("dictation transcribed route=\(route) model=\(model) audio_ms=\(audio) stop_to_text_ms=\(milliseconds(stopToText)) characters=\(characters)")
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int((duration / .milliseconds(1)).rounded())
    }

    /// Archived recordings retain their frozen plan; older recovery recordings
    /// use the current local settings.
    func transcribe(_ recording: DictationRecording<ExecutionTarget>) async throws -> DictationTranscript {
        let local = configuration()
        let resolved = try await library?.plan(for: recording.id)
        let configuration = try resolved.map { try TranscriptionConfiguration(plan: $0.plan, local: local) } ?? local
        await recordAttempt(recordingID: recording.id, audio: .complete(recording), live: nil, outcome: "retry")
        do {
            let result = try await withAccount(resolved?.account) { [self] in
                let raw = try await transcribe(recording, configuration: configuration)
                let result = try await archiveResult(raw, recordingID: recording.id, plan: resolved?.plan)
                VoiceModeDiagnostics.log("saved recording transcribed characters=\(result.text.count)")
                return result
            }
            await recordAttempt(recordingID: recording.id, audio: .complete(recording), live: nil, outcome: "text")
            return result
        } catch {
            if !(error is CancellationError) {
                logger.error("saved dictation failed id=\(recording.id) error=\(error.localizedDescription)")
            }
            await recordAttempt(recordingID: recording.id, audio: .complete(recording), live: nil,
                                outcome: error is CancellationError ? "cancelled" : "failed")
            throw error
        }
    }

    private func transcribe(_ recording: DictationRecording<ExecutionTarget>, configuration: TranscriptionConfiguration) async throws -> DictationTranscript {
        do {
            return try await transcriber.transcribe(recording, configuration: configuration)
        } catch RemoteCoderTranscriptionService.ServiceError.emptyResponse {
            return DictationTranscript(text: "", model: configuration.model.batchLibraryID)
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

    private func prepareRecognition() async -> DictationVoiceSession {
        do { return DictationVoiceSession(state: .active(try await voices.makeCheck(for: owner.hostID))) }
        catch { return DictationVoiceSession(state: .unavailable(error)) }
    }

    private func startRecording() async throws {
        let local = configuration()
        let archive = try await library?.prepare(configuration: local)
        var recoveryWriter: DictationRecordingWriter<ExecutionTarget>?
        var liveDictation: RealtimeDictation?
        var recognition = DictationVoiceSession(state: .off)
        do {
            captureAccountMonitor?.cancel()
            captureAccountMonitor = nil
            if let archive, let account = archive.account, let library {
                try await library.validateAccount(account)
                captureAccountMonitor = Task { [weak self] in
                    guard (try? await library.waitForAccountChange(from: account)) != nil else { return }
                    await self?.captureAccountChanged(id: archive.id)
                }
            }
            let configuration = try archive.map { try TranscriptionConfiguration(plan: $0.plan, local: local) } ?? local
            let realtime: RealtimeTranscription?
            if configuration.voices == .onlyMine {
                async let preparedRecognition = prepareRecognition()
                do { realtime = try await transcriber.makeRealtimeTranscription(configuration: configuration) }
                catch { await preparedRecognition.cancel(); throw error }
                recognition = await preparedRecognition
            } else {
                realtime = try await transcriber.makeRealtimeTranscription(configuration: configuration)
            }
            if let account = archive?.account { try await library?.validateAccount(account) }
            try Task.checkCancellation()
            let sampleRate = realtime?.session.sampleRate ?? TranscriptionCapture.batchSampleRate
            let live = realtime.map { LiveTranscription(dictation: RealtimeDictation(session: $0.session), provider: $0.provider,
                                                         progressive: $0.session as? ProgressiveRealtimeTranscriptionSession) }
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
            if recognition.isActive {
                let recognition = recognition
                output.receiveRecognition = { recognition.append($0) }
                output.recognitionFailed = { recognition.invalidate($0) }
            }
            try await recorder.start(output: output)
            if let account = archive?.account { try await library?.validateAccount(account) }
            active = ActiveDictation(writer: writer, live: live, configuration: configuration, archive: archive,
                                     recognition: recognition)
            inFlightRecordingID = writer.id
        } catch {
            recorder.stop()
            await liveDictation?.cancel()
            await recognition.cancel()
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
            await active?.live?.dictation.cancel()
            await active?.recognition.cancel()
            do { try await stopRecording() }
            catch { logger.error("account-change capture stop failed: \(error.localizedDescription)") }
        }
        if stopped?.recordingID == id {
            await stopped?.live?.dictation.cancel()
            await stopped?.recognition.cancel()
            stopped = nil
        }
        if inFlightRecordingID == id { inFlightRecordingID = nil }
        isTranscribing = false
        library?.accountChanged()
    }

    private func withAccount<Value: Sendable>(_ account: DictationAccountSession?,
        operation: @escaping @MainActor @Sendable () async throws -> Value) async throws -> Value {
        guard let account, let library else { return try await operation() }
        try await library.validateAccount(account)
        let result = try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await library.waitForAccountChange(from: account)
                throw DictationLibraryError.accountChanged
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
        try await library.validateAccount(account)
        return result
    }

    private func archiveResult(_ transcript: DictationTranscript, recordingID: UUID, plan: DictationLibrary.DictationPlan?) async throws -> DictationTranscript {
        guard let plan, let library else { return transcript }
        return try await library.result(transcript, recordingID: recordingID, plan: plan, access: access)
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
