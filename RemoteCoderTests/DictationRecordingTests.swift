import Foundation
import SpeechKit
import Synchronization
import Testing
@testable import RemoteCoder

@MainActor
struct DictationRecordingTests {
    private let owner = ExecutionTarget(hostID: UUID())

    @Test(.timeLimit(.minutes(1))) func cancellingAnUnansweredPermissionRequestFinishesWithoutWaitingForItsLateGrant() async throws {
        let reply = HeldPermissionReply()
        let entered = AsyncStream<Void>.makeStream()
        let request = Task {
            try await VoiceInputPermissions.awaitMicrophonePermission { completion in
                reply.store(completion)
                entered.continuation.yield()
            }
        }
        for await _ in entered.stream { break }
        request.cancel()
        await #expect(throws: CancellationError.self) { _ = try await request.value }
        reply.complete(true)
        entered.continuation.finish()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [0, 3_200])
    func quitJoinsAnAdmittedStopAndReportsItsRecordingSaveFailure(_ prefixByteCount: Int) async throws {
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let recorder = HeldStopRecorder(prefixByteCount: prefixByteCount)
        defer { recorder.release() }
        let controller = VoiceInputController(access: .fixture, owner: owner, transcriber: StubTranscriber(text: "unused"),
            recorder: recorder, recordings: recordings.store)
        controller.markRecordingRequested()
        try await controller.startAsync()
        let stop = Task { try await controller.stopRecording() }
        try #require(await waitUntil { recorder.isHeld })
        var completed = false
        let quit = Task {
            defer { completed = true }
            try await controller.quiesceForTermination()
        }
        await Task.yield()
        #expect(!completed)
        recorder.release()
        try await stop.value
        await #expect(throws: DictationError.self) { try await quit.value }
        #expect(recorder.stops == 1)
        await #expect(throws: DictationError.self) { try await controller.quiesceForTermination() }
    }

    @Test(.timeLimit(.minutes(1))) func keepOpenMakesACancelledRecoveryTranscriptionRetryable() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let screen = try #require(fixture.workspace.selectedScreen)
        try #require(await screen.prepareDraft())
        let transcriber = HeldRecoveryTranscriber()
        screen.target.voice = VoiceInputController(access: .fixture, owner: screen.executionTarget,
            transcriber: transcriber, recorder: StubVoiceRecorder(), recordings: recordings.store)
        let recording = try await recordings.save(owner: screen.executionTarget)
        screen.dictation.refreshRecoverable()
        try #require(await waitUntil { screen.recoverableDictations.contains { $0.id == recording.id } })
        screen.transcribeRecoverableDictation(recording.id)
        try #require(await waitUntil { await transcriber.isHeld })
        fixture.workspace.beginTermination()
        #expect(await fixture.workspace.flushForTermination().isEmpty)
        fixture.workspace.resumeAfterTermination()
        try #require(await waitUntil { screen.recoverableDictations.first?.status == .waiting })
        screen.transcribeRecoverableDictation(recording.id)
        #expect(await waitUntil { screen.input == "Recovered after Keep Open" })
    }

    @Test func realtimeTranscriptKeepsTheSavedRecording() async throws {
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let session = ScriptedRealtimeSession(answer: .finalized("spoken live"), finalizationTimeout: .seconds(5))
        let transcriber = ScriptedTranscriber(realtime: session, batchText: "from batch")
        let controller = VoiceInputController(access: .fixture, owner: owner, transcriber: transcriber,
                                              recorder: StubVoiceRecorder(), recordings: recordings.store)

        controller.markRecordingRequested()
        try await controller.startAsync()
        try await controller.stopRecording()
        #expect(try await controller.savedRecordings().isEmpty)
        let dictation = try await controller.transcribe()

        #expect(dictation.text == "spoken live")
        let recording = try #require(dictation.recording)
        #expect(recording.id == dictation.recordingID)
        #expect(recording.owner == owner)
        #expect(!recording.wasInterrupted)
        #expect(recording.duration == .milliseconds(100))
        #expect(await session.receivedByteCount == 3_200)
        #expect(transcriber.batchRecordingIDs.isEmpty)
        #expect(try await recordings.listedIDs() == [recording.id])
    }

    @Test func realtimeTranscriptThatNeverFinalizesTranscribesTheSameSavedAudioOnce() async throws {
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let session = ScriptedRealtimeSession(answer: .committedOnly("half of it"), finalizationTimeout: .milliseconds(100))
        let transcriber = ScriptedTranscriber(realtime: session, batchText: "from batch")
        let controller = VoiceInputController(access: .fixture, owner: owner, transcriber: transcriber,
                                              recorder: StubVoiceRecorder(), recordings: recordings.store)

        controller.markRecordingRequested()
        try await controller.startAsync()
        try await controller.stopRecording()
        let dictation = try await controller.transcribe()

        #expect(dictation.text == "from batch")
        #expect(transcriber.batchRecordingIDs == [dictation.recordingID])
        #expect(dictation.recording?.duration == .milliseconds(100))
    }

    @Test func cancellingTheRealtimeTranscriptKeepsTheRecordingWithoutABatchUpload() async throws {
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let session = ScriptedRealtimeSession(answer: .committedOnly("unfinished"), finalizationTimeout: .seconds(600))
        let transcriber = ScriptedTranscriber(realtime: session, batchText: "unused")
        let controller = VoiceInputController(access: .fixture, owner: owner, transcriber: transcriber,
                                              recorder: StubVoiceRecorder(), recordings: recordings.store)

        controller.markRecordingRequested()
        try await controller.startAsync()
        try await controller.stopRecording()
        let transcription = Task { try await controller.transcribe() }
        #expect(await waitUntil { await session.commitCount == 1 })
        transcription.cancel()

        await #expect(throws: CancellationError.self) { try await transcription.value }
        #expect(transcriber.batchRecordingIDs.isEmpty)
        #expect(try await controller.savedRecordings().map(\.duration) == [.milliseconds(100)])
    }

    @Test func failedBatchTranscriptionLeavesTheRecordingRecoverable() async throws {
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let transcriber = ScriptedTranscriber(realtime: nil, batchText: nil)
        let controller = VoiceInputController(access: .fixture, owner: owner, transcriber: transcriber,
                                              recorder: StubVoiceRecorder(), recordings: recordings.store)
        let otherHost = try await recordings.save(owner: ExecutionTarget(hostID: UUID()))

        controller.markRecordingRequested()
        try await controller.startAsync()
        try await controller.stopRecording()
        await #expect(throws: ScriptedTranscriber.Failure.self) { try await controller.transcribe() }

        let saved = try await controller.savedRecordings()
        #expect(saved.map(\.id) == transcriber.batchRecordingIDs)
        #expect(saved.first?.owner == owner)
        #expect(saved.first?.wasInterrupted == false)
        #expect(try await recordings.listedIDs() == Set(saved.map(\.id) + [otherHost.id]))
    }

    @Test func recoveryDiscardsReceivedAudioAndInsertsTheRestOnce() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        #expect(await model.prepareDraft())
        model.target.voice = VoiceInputController(access: .fixture, owner: model.executionTarget,
                                           transcriber: StubTranscriber(text: "recovered words"),
                                           recorder: StubVoiceRecorder(), recordings: recordings.store)
        let received = try await recordings.save(owner: model.executionTarget)
        let pending = try await recordings.save(owner: model.executionTarget)
        let otherHost = try await recordings.save(owner: ExecutionTarget(hostID: fixture.book.id))
        try await model.drafts.appendDictation("already received", recordingID: received.id, to: try #require(model.currentDraft))
        #expect(await model.drafts.flush())

        model.dictation.refreshRecoverable()
        #expect(await waitUntil { model.recoverableDictations.map(\.id) == [pending.id] })
        #expect(try await waitUntil { try await recordings.listedIDs() == [pending.id, otherHost.id] })
        #expect(model.input == "already received")

        model.transcribeRecoverableDictation(pending.id)
        model.transcribeRecoverableDictation(pending.id)
        #expect(try await waitUntil { try await recordings.listedIDs() == [otherHost.id] })
        #expect(model.recoverableDictations.isEmpty)
        #expect(model.input == "already received recovered words")
        #expect(try await model.drafts.hasSavedReceipt(for: pending.id))
    }

    @Test func aReceiptThatWasNeverSavedKeepsItsRecordingRecoverable() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        #expect(await model.prepareDraft())
        model.target.voice = VoiceInputController(access: .fixture, owner: model.executionTarget,
                                           transcriber: StubTranscriber(text: "never saved"),
                                           recorder: StubVoiceRecorder(), recordings: recordings.store)
        let recording = try await recordings.save(owner: model.executionTarget)
        try await model.drafts.appendDictation("never saved", recordingID: recording.id, to: try #require(model.currentDraft))

        model.dictation.refreshRecoverable()
        #expect(await waitUntil { model.recoverableDictations.map(\.id) == [recording.id] })
        #expect(try await recordings.listedIDs() == [recording.id])

        model.transcribeRecoverableDictation(recording.id)
        #expect(try await waitUntil { try await recordings.listedIDs().isEmpty })
        #expect(model.input == "never saved")
        #expect(try await model.drafts.hasSavedReceipt(for: recording.id))
    }

    @Test func offlineDictationIsTranscribedFromItsSavedAudioThenDiscarded() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        #expect(await model.prepareDraft())
        let transcriber = ScriptedTranscriber(realtime: UnreachableRealtimeSession(), batchText: "spoken offline")
        model.target.voice = VoiceInputController(access: .fixture, owner: model.executionTarget, transcriber: transcriber,
                                           recorder: StubVoiceRecorder(), recordings: recordings.store)

        model.micTapStart()
        await model.micTapStartAsync()
        #expect(model.target.voice.recordingStartTime != nil)
        model.micTapStopImmediate()
        await model.micTapStopAsync()

        #expect(model.target.voiceError == nil)
        #expect(model.input == "spoken offline")
        let recordingID = try #require(transcriber.batchRecordingIDs.first)
        #expect(transcriber.batchRecordingIDs == [recordingID])
        #expect(try await model.drafts.hasSavedReceipt(for: recordingID))
        #expect(try await recordings.listedIDs().isEmpty)
        #expect(model.recoverableDictations.isEmpty)
    }

    @Test func dictationThatCannotBeTranscribedBecomesATileThatExplainsItsFailure() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        #expect(await model.prepareDraft())
        let transcriber = ScriptedTranscriber(realtime: UnreachableRealtimeSession(), batchText: nil)
        model.target.voice = VoiceInputController(access: .fixture, owner: model.executionTarget, transcriber: transcriber,
                                           recorder: StubVoiceRecorder(), recordings: recordings.store)

        model.micTapStart()
        await model.micTapStartAsync()
        model.micTapStopImmediate()
        await model.micTapStopAsync()

        #expect(model.target.voiceError != nil)
        let recordingID = try #require(transcriber.batchRecordingIDs.first)
        #expect(await waitUntil { model.recoverableDictations.map(\.id) == [recordingID] })

        model.target.voiceError = nil
        model.transcribeRecoverableDictation(recordingID)
        #expect(await waitUntil {
            if case .failed = model.recoverableDictations.first?.status { true } else { false }
        })
        #expect(model.target.voiceError != nil)
        #expect(model.input.isEmpty)
        #expect(try await recordings.listedIDs() == [recordingID])
    }

    @Test func aTileWhoseRecordingIsGoneIsDroppedInsteadOfOfferingRetry() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let model = try #require(fixture.workspace.selectedScreen)
        #expect(await model.prepareDraft())
        let transcriber = ScriptedTranscriber(realtime: nil, batchText: "unreachable")
        model.target.voice = VoiceInputController(access: .fixture, owner: model.executionTarget, transcriber: transcriber,
                                           recorder: StubVoiceRecorder(), recordings: recordings.store)
        let recording = try await recordings.save(owner: model.executionTarget)
        model.dictation.refreshRecoverable()
        #expect(await waitUntil { model.recoverableDictations.map(\.id) == [recording.id] })

        try await recordings.store.discard(recording)
        model.transcribeRecoverableDictation(recording.id)

        #expect(await waitUntil { model.recoverableDictations.isEmpty })
        #expect(transcriber.batchRecordingIDs == [recording.id])
        #expect(model.target.voiceError == nil)
        #expect(model.input.isEmpty)
    }

    @Test func stopDuringStartEndsItQuietlyWhenNothingWasCaptured() async throws {
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let recorder = GatedVoiceRecorder(gate: .activation)
        let controller = VoiceInputController(access: .fixture, owner: owner,
                                              transcriber: ScriptedTranscriber(realtime: nil, batchText: "unused"),
                                              recorder: recorder, recordings: recordings.store)

        controller.markRecordingRequested()
        let start = Task { try await controller.startAsync() }
        #expect(await waitUntil { recorder.isHeld })
        let stop = Task { try await controller.stopRecording() }
        #expect(await waitUntil { recorder.startWasCancelled })
        recorder.release()

        await #expect(throws: CancellationError.self) { try await start.value }
        await #expect(throws: CancellationError.self) { try await stop.value }
        #expect(!recorder.didStart)
        #expect(!controller.isRecording)
        #expect(try await recordings.listedIDs().isEmpty)
    }

    @Test func stopDuringStartStopsTheCaptureItOpenedAndKeepsTheAudio() async throws {
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let recorder = GatedVoiceRecorder(gate: .captureStart)
        let transcriber = ScriptedTranscriber(realtime: nil, batchText: "said while starting")
        let controller = VoiceInputController(access: .fixture, owner: owner, transcriber: transcriber,
                                              recorder: recorder, recordings: recordings.store)

        controller.markRecordingRequested()
        let start = Task { try await controller.startAsync() }
        #expect(await waitUntil { recorder.isHeld })
        let stop = Task { try await controller.stopRecording() }
        #expect(await waitUntil { recorder.startWasCancelled })
        recorder.release()

        try await start.value
        try await stop.value
        #expect(recorder.didStop)
        #expect(!controller.isRecording)
        let dictation = try await controller.transcribe()
        #expect(dictation.text == "said while starting")
        #expect(dictation.recording?.duration == .milliseconds(100))
        #expect(transcriber.batchRecordingIDs == [dictation.recordingID])
    }

    @Test func failedCaptureStartKeepsARecordingOnlyWhenItCapturedAudio() async throws {
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let silent = VoiceInputController(access: .fixture, owner: owner,
                                          transcriber: ScriptedTranscriber(realtime: nil, batchText: "unused"),
                                          recorder: FailingCaptureRecorder(capturedByteCount: 0),
                                          recordings: recordings.store)
        silent.markRecordingRequested()
        await #expect(throws: FailingCaptureRecorder.Failure.self) { try await silent.startAsync() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: recordings.directory.path).isEmpty)

        let heard = VoiceInputController(access: .fixture, owner: owner,
                                         transcriber: ScriptedTranscriber(realtime: nil, batchText: "unused"),
                                         recorder: FailingCaptureRecorder(capturedByteCount: 3_200),
                                         recordings: recordings.store)
        heard.markRecordingRequested()
        await #expect(throws: FailingCaptureRecorder.Failure.self) { try await heard.startAsync() }
        let kept = try await heard.savedRecordings()
        #expect(kept.map(\.duration) == [.milliseconds(100)])
    }
}

nonisolated private final class HeldPermissionReply: Sendable {
    private let callback = Mutex<(@Sendable (Bool) -> Void)?>(nil)
    func store(_ completion: @escaping @Sendable (Bool) -> Void) { callback.withLock { $0 = completion } }
    func complete(_ granted: Bool) { callback.withLock { $0 }?(granted) }
}

@MainActor
private final class HeldStopRecorder: VoiceInputRecording {
    private let prefixByteCount: Int
    private var held: CheckedContinuation<Void, Never>?
    private(set) var stops = 0
    var isHeld: Bool { held != nil }
    init(prefixByteCount: Int) { self.prefixByteCount = prefixByteCount }
    func release() { held?.resume(); held = nil }
    func ensurePermission() async throws {}
    func activateSession() async throws {}
    func deactivateSession() async throws { await withCheckedContinuation { held = $0 } }
    func start(output: PCM16CaptureOutput) async throws {
        if prefixByteCount > 0 { output.receive(Data(repeating: 1, count: prefixByteCount)) }
        output.receive(Data([1]))
    }
    func stop() { stops += 1 }
    func levels() -> AsyncStream<[Float]> { AsyncStream { $0.finish() } }
}

private final class HeldRecoveryTranscriber: TranscriptionService {
    private let gate = HeldRecoveryGate()
    var isHeld: Bool { get async { await gate.isHeld } }
    func makeRealtimeTranscription(configuration: TranscriptionConfiguration) async throws -> RealtimeTranscription? { nil }
    @concurrent
    func transcribe(_ recording: DictationRecording<ExecutionTarget>, configuration: TranscriptionConfiguration) async throws -> String {
        try await gate.read()
    }
}

private actor HeldRecoveryGate {
    private var continuation: CheckedContinuation<String, any Error>?
    private var hasRequested = false
    var isHeld: Bool { continuation != nil }
    func read() async throws -> String {
        if hasRequested { return "Recovered after Keep Open" }
        hasRequested = true
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: { Task { await self.cancel() } }
    }
    private func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

private actor ScriptedRealtimeSession: RealtimeTranscriptionSession {
    enum Answer {
        case finalized(String)
        case committedOnly(String)
    }

    nonisolated let sampleRate = 16_000
    nonisolated let finalizationTimeout: Duration
    private let answer: Answer
    private var continuation: AsyncThrowingStream<RealtimeTranscriptionEvent, Error>.Continuation?
    private(set) var receivedByteCount = 0
    private(set) var commitCount = 0

    init(answer: Answer, finalizationTimeout: Duration) {
        self.answer = answer
        self.finalizationTimeout = finalizationTimeout
    }

    func connectTranscription() -> AsyncThrowingStream<RealtimeTranscriptionEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<RealtimeTranscriptionEvent, Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    func sendAudioChunk(_ audioData: Data) {
        receivedByteCount += audioData.count
    }

    func requestCommit() {
        commitCount += 1
        switch answer {
        case .finalized(let text):
            continuation?.yield(.committedTranscript(text))
            continuation?.yield(.finalizationCompleted)
        case .committedOnly(let text):
            continuation?.yield(.committedTranscript(text))
        }
    }

    func disconnect() {
        continuation?.finish()
    }
}

private struct UnreachableRealtimeSession: RealtimeTranscriptionSession {
    struct Offline: Error {}

    let sampleRate = 16_000
    let finalizationTimeout = Duration.seconds(5)

    func connectTranscription() async throws -> AsyncThrowingStream<RealtimeTranscriptionEvent, Error> {
        throw Offline()
    }

    func sendAudioChunk(_ audioData: Data) async throws {}
    func requestCommit() async throws {}
    func disconnect() async {}
}

private final class ScriptedTranscriber: TranscriptionService {
    struct Failure: Error {}

    private let session: (any RealtimeTranscriptionSession)?
    private let batchText: String?
    private let batchCalls = Mutex<[UUID]>([])

    init(realtime session: (any RealtimeTranscriptionSession)?, batchText: String?) {
        self.session = session
        self.batchText = batchText
    }

    var batchRecordingIDs: [UUID] { batchCalls.withLock { $0 } }

    func makeRealtimeTranscription(configuration: TranscriptionConfiguration) async throws -> RealtimeTranscription? {
        session.map { RealtimeTranscription(session: $0, provider: .elevenLabs) }
    }

    @concurrent
    func transcribe(_ recording: DictationRecording<ExecutionTarget>, configuration: TranscriptionConfiguration) async throws -> String {
        batchCalls.withLock { $0.append(recording.id) }
        _ = try await recording.transcriptionAudio(maximumByteCount: 1_000_000)
        guard let batchText else { throw Failure() }
        return batchText
    }
}

@MainActor
private final class GatedVoiceRecorder: VoiceInputRecording {
    enum Gate {
        case activation
        case captureStart
    }

    private let gate: Gate
    private let cancelled = Mutex(false)
    private var held: CheckedContinuation<Void, Never>?
    private(set) var didStart = false
    private(set) var didStop = false

    init(gate: Gate) {
        self.gate = gate
    }

    var isHeld: Bool { held != nil }
    var startWasCancelled: Bool { cancelled.withLock { $0 } }

    func release() {
        held?.resume()
        held = nil
    }

    func ensurePermission() async throws {}

    func activateSession() async throws {
        if gate == .activation { await hold() }
    }

    func deactivateSession() async throws {}

    func start(output: PCM16CaptureOutput) async throws {
        didStart = true
        output.receive(Data(repeating: 1, count: 3_200))
        if gate == .captureStart { await hold() }
    }

    func stop() { didStop = true }
    func levels() -> AsyncStream<[Float]> { AsyncStream { $0.finish() } }

    private func hold() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { held = $0 }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }
}

@MainActor
private final class FailingCaptureRecorder: VoiceInputRecording {
    struct Failure: Error {}

    private let capturedByteCount: Int

    init(capturedByteCount: Int) {
        self.capturedByteCount = capturedByteCount
    }

    func ensurePermission() async throws {}
    func activateSession() async throws {}
    func deactivateSession() async throws {}

    func start(output: PCM16CaptureOutput) async throws {
        if capturedByteCount > 0 { output.receive(Data(repeating: 1, count: capturedByteCount)) }
        throw Failure()
    }

    func stop() {}
    func levels() -> AsyncStream<[Float]> { AsyncStream { $0.finish() } }
}
