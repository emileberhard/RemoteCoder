import Foundation
import SpeakerRecognition
import SpeechKit
import Synchronization

nonisolated final class DictationVoiceSession: Sendable {
    private let check: VoiceCheck
    private let audio = RecognitionAudio()
    private let uploadTime = Mutex<Duration?>(nil)
    private let captureFailed = Mutex(false)

    private let budget: @Sendable (Int) -> Duration

    init(check: VoiceCheck, budget: @escaping @Sendable (Int) -> Duration = {
        min(.seconds(6), .seconds(4) + .milliseconds($0 * 8 / 16_000))
    }) {
        self.check = check
        self.budget = budget
    }

    enum Failure: Error { case recognitionFormatUnavailable }

    func invalidate() { captureFailed.withLock { $0 = true }; audio.release() }

    func append(_ pcm16: Data) {
        audio.append(pcm16)
        check.append(pcm16)
    }

    func finish(fetch: @escaping @Sendable (Data, @escaping @Sendable (Duration) -> Void) async throws -> [SpeakerPhrase]) async {
        if captureFailed.withLock({ $0 }) { await check.cancel(); return }
        await check.finish { [self] in
            let pcm = try audio.take()
            return try await fetch(pcm) { [self] duration in uploadTime.withLock { $0 = duration } }
        }
    }

    func resolve(_ original: DictationTranscript) async throws
        -> (transcript: DictationTranscript, result: VoiceCheckResult?, upload: Duration?, wait: Duration) {
        defer { audio.release() }
        try Task.checkCancellation()
        if captureFailed.withLock({ $0 }) {
            return (DictationTranscript(text: original.text, everyone: original.everyone, model: original.model,
                everyoneModel: original.everyoneModel, outcome: .failed), nil, nil, .zero)
        }
        let started = ContinuousClock.now
        let result = try await check.resolve(everyone: original.text, waitingUpTo: budget(audio.sampleCount))
        let transcript = DictationTranscript(text: result.text, everyone: original.text,
            model: result.outcome.droppedCount > 0 ? TranscriptionModel.azureMAITranscribe2.batchLibraryID : original.model,
            everyoneModel: original.model, outcome: result.outcome)
        return (transcript, result, uploadTime.withLock { $0 }, started.duration(to: .now))
    }

    func cancel() async {
        audio.release()
        await check.cancel()
    }
}

nonisolated private final class RecognitionAudio: Sendable {
    private struct State {
        var chunks: [Data] = []
        var bytes = 0
        var complete = true
    }
    private let state = Mutex(State())

    var sampleCount: Int { state.withLock { $0.bytes / 2 } }

    func append(_ data: Data) {
        state.withLock { state in
            guard state.complete else { return }
            guard data.count.isMultiple(of: 2), state.bytes + data.count <= VoiceCheck.maximumSamples * 2 else {
                state = State(chunks: [], bytes: 0, complete: false)
                return
            }
            state.chunks.append(data)
            state.bytes += data.count
        }
    }

    func take() throws -> Data {
        let saved = state.withLock { state in
            let saved = state
            state = State(chunks: [], bytes: saved.bytes, complete: false)
            return saved
        }
        guard saved.complete else { throw CocoaError(.fileReadTooLarge) }
        var pcm = Data(capacity: saved.bytes)
        for chunk in saved.chunks { pcm.append(chunk) }
        return pcm
    }

    func release() { state.withLock { $0 = State(chunks: [], bytes: 0, complete: false) } }
}
