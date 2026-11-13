import Foundation
import SpeakerRecognition
import SpeechKit
import Synchronization

nonisolated final class DictationVoiceSession: Sendable {
    enum State: Sendable {
        case off
        case unavailable(any Error)
        case active(VoiceCheck)
    }

    struct Resolution: Sendable {
        let transcript: DictationTranscript
        let check: Result<VoiceCheckResult, any Error>?
        let upload: Duration?
        let wait: Duration
    }

    private let state: Mutex<State>
    private let samples = Mutex(0)
    private let uploadTime = Mutex<Duration?>(nil)
    private let budget: @Sendable (Int) -> Duration

    init(state: State, budget: @escaping @Sendable (Int) -> Duration = {
        min(.seconds(6), .seconds(4) + .milliseconds($0 * 9 / 16_000))
    }) {
        self.state = Mutex(state)
        self.budget = budget
    }

    var isActive: Bool { state.withLock { if case .active = $0 { true } else { false } } }

    func invalidate(_ error: any Error) {
        let check: VoiceCheck? = state.withLock { current in
            guard case .active(let check) = current else { return nil }
            current = .unavailable(error)
            return check
        }
        if let check { Task { await check.cancel() } }
    }

    func append(_ pcm16: Data) {
        guard case .active(let check) = state.withLock({ $0 }) else { return }
        samples.withLock { $0 = min(VoiceCheck.maximumSamples, $0 + pcm16.count / 2) }
        check.append(pcm16)
    }

    func finish(fetch: @escaping @Sendable (Data, @escaping @Sendable (Duration) -> Void) async throws -> [SpeakerPhrase]) async {
        guard case .active(let check) = state.withLock({ $0 }) else { return }
        await check.finish { [weak self] pcm in
            try await fetch(pcm) { [weak self] duration in self?.uploadTime.withLock { $0 = duration } }
        }
    }

    func resolve(_ original: DictationTranscript) async throws -> Resolution {
        try Task.checkCancellation()
        let started = ContinuousClock.now
        switch state.withLock({ $0 }) {
        case .off: return Resolution(transcript: original, check: nil, upload: nil, wait: .zero)
        case .unavailable(let error): return failed(original, error: error)
        case .active(let check):
            do {
                let result = try await check.resolve(everyone: original.text,
                    linesAreSpeakerTurns: DictationVoicePolicy.breaksLinesAtSpeakerTurns(original.model),
                    waitingUpTo: budget(samples.withLock { $0 }))
                try Task.checkCancellation()
                if case .unavailable(let error) = state.withLock({ $0 }) { return failed(original, error: error) }
                let transcript = DictationTranscript(text: result.text, everyone: result.everyone,
                    model: result.outcome.droppedCount > 0 ? DictationVoicePolicy.labelledModel.selection.batchLibraryID : original.model,
                    everyoneModel: original.model, outcome: result.outcome)
                return Resolution(transcript: transcript, check: .success(result), upload: uploadTime.withLock { $0 }, wait: started.duration(to: .now))
            } catch {
                try Task.checkCancellation()
                if case .unavailable(let failure) = state.withLock({ $0 }) { return failed(original, error: failure) }
                throw error
            }
        }
    }

    private func failed(_ original: DictationTranscript, error: any Error) -> Resolution {
        Resolution(transcript: DictationTranscript(text: original.text, everyone: original.everyone, model: original.model,
            everyoneModel: original.everyoneModel, outcome: .failed), check: .failure(error), upload: nil, wait: .zero)
    }

    func cancel() async {
        let check: VoiceCheck? = state.withLock { current in
            guard case .active(let check) = current else { return nil }
            current = .off
            return check
        }
        await check?.cancel()
    }
}
