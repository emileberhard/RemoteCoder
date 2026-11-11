import AVFoundation
import Foundation
import SpeakerRecognition
import SpeechKit
import Synchronization
import Testing
@testable import RemoteCoder

@Suite(.serialized, .timeLimit(.minutes(1)))
struct DictationVoiceTests {
    @Test @MainActor func everyoneSkipsRecognitionEvenWithTheAzureModel() async throws {
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let name = "EveryoneVoices.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = URL.temporaryDirectory.appending(path: name)
        defer { try? FileManager.default.removeItem(at: directory) }
        let voices = DictationVoiceProfiles(defaults: defaults, directory: directory)
        let recorder = VoiceFixtureRecorder()
        let controller = VoiceInputController(access: .fixture, owner: ExecutionTarget(hostID: UUID()),
            transcriber: StubTranscriber(text: "Selected provider text."), recorder: recorder, recordings: recordings.store,
            voices: voices, configuration: { .init(model: .azureMAITranscribe2, language: .english, voiceChoice: .everyone) })
        controller.markRecordingRequested()
        try await controller.startAsync()
        try await controller.stopRecording()
        let result = try await controller.transcribe()
        #expect(result.text == "Selected provider text.")
        #expect(result.transcript.outcome == nil)
        #expect(!recorder.recognitionWasAttached)
    }

    @Test @MainActor func transientFailuresKeepProfileStatusAndRefusalMarksTheRoute() async throws {
        let name = "VoiceStatus.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = URL.temporaryDirectory.appending(path: name)
        defer { try? FileManager.default.removeItem(at: directory) }
        let voices = DictationVoiceProfiles(defaults: defaults, directory: directory)
        voices.failed(URLError(.timedOut))
        #expect(voices.status == .learning)
        voices.failed(SpeechKitError.invalidResponse, stage: .learning)
        #expect(voices.status == .learning)
        voices.failed(SpeechKitError.relayRejected(kind: "credentialsUnavailable"))
        #expect(voices.status == .unavailable)
    }

    @Test(arguments: [false, true]) @MainActor func controllerUsesItsInjectedSpeakerRequest(refused: Bool) async throws {
        let fixture = try await VoiceFixture(trusted: true)
        defer { fixture.cleanUp() }
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let name = "InjectedVoice.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let voices = DictationVoiceProfiles(defaults: defaults, directory: fixture.directory)
        let transcriber = InjectedVoiceTranscriber(phrases: fixture.phrases, refused: refused)
        let controller = VoiceInputController(access: .fixture, owner: ExecutionTarget(hostID: UUID()),
            transcriber: transcriber, recorder: VoiceFixtureRecorder(pcm: fixture.mix), recordings: recordings.store,
            voices: voices, configuration: { .init(model: .openAIGPT4oMini, language: .english, voiceChoice: .onlyMine) })
        controller.markRecordingRequested()
        try await controller.startAsync()
        try await controller.stopRecording()
        let result = try await controller.transcribe()
        #expect(result.transcript.everyone == "Selected provider text.")
        if refused {
            #expect(result.text == "Selected provider text.")
            #expect(result.transcript.outcome?.path == .failed)
            #expect(try await waitUntil { voices.status == .unavailable })
        } else {
            #expect(result.text == "Only my words.")
            #expect(result.transcript.model == TranscriptionModel.azureMAITranscribe2.batchLibraryID)
        }
        #expect(transcriber.requestCount.withLock { $0 } == 1)
    }

    @Test @MainActor func defaultsFollowTheResolvedModelUntilAnExplicitChoice() throws {
        let name = "DictationVoiceTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(TranscriptionConfiguration(model: .azureMAITranscribe2, language: .automatic).voices == .onlyMine)
        #expect(TranscriptionConfiguration(model: .openAIGPT4oTranscribeRealtime, language: .automatic).voices == .everyone)
        #expect(TranscriptionSettings.voiceChoice(defaults: defaults) == nil)
        TranscriptionSettings.setVoices(.onlyMine, defaults: defaults)
        #expect(TranscriptionSettings.voiceChoice(defaults: defaults) == .onlyMine)
        #expect(TranscriptionConfiguration(model: .openAIGPT4oTranscribeRealtime, language: .automatic,
            voiceChoice: TranscriptionSettings.voiceChoice(defaults: defaults)).voices == .onlyMine)
    }

    @Test func filteredDeliveryCarriesAzureProvenanceAndEveryonesOriginalText() async throws {
        let fixture = try await VoiceFixture(trusted: true)
        defer { fixture.cleanUp() }
        let session = DictationVoiceSession(check: fixture.check)
        let requested = AsyncStream<Void>.makeStream()
        session.append(fixture.mix)
        await session.finish { pcm, uploaded in
            #expect(pcm == fixture.mix)
            uploaded(.milliseconds(12))
            requested.continuation.yield(())
            requested.continuation.finish()
            return fixture.phrases
        }
        for await _ in requested.stream { break }
        let original = DictationTranscript(text: "Selected provider's complete words.", model: "selected/model")
        let result = try await session.resolve(original)
        #expect(result.transcript.text == "Only my words.")
        #expect(result.transcript.everyone == original.text)
        #expect(result.transcript.model == TranscriptionModel.azureMAITranscribe2.batchLibraryID)
        #expect(result.transcript.everyoneModel == original.model)
        #expect(result.transcript.removedVoices)
        #expect(result.upload == .milliseconds(12))
        await session.cancel()
    }

    @Test(arguments: [false, true])
    func untrustedAndOneVoiceDeliveryNeverFetchLabels(trusted: Bool) async throws {
        let fixture = try await VoiceFixture(trusted: trusted)
        defer { fixture.cleanUp() }
        let session = DictationVoiceSession(check: fixture.check)
        let called = Mutex(false)
        session.append(fixture.owner)
        await session.finish { _, _ in
            called.withLock { $0 = true }
            throw URLError(.cannotConnectToHost)
        }
        let original = DictationTranscript(text: "Original selected text.", model: "selected/model")
        let result = try await session.resolve(original)
        #expect(result.transcript.text == original.text)
        #expect(result.transcript.model == original.model)
        #expect(!called.withLock { $0 })
        await session.cancel()
    }

    @Test(arguments: [false, true])
    func refusalAndAnOverBudgetReplyKeepTheSelectedTranscript(slow: Bool) async throws {
        let fixture = try await VoiceFixture(trusted: true)
        defer { fixture.cleanUp() }
        let session = DictationVoiceSession(check: fixture.check, budget: { _ in .milliseconds(5) })
        let requested = AsyncStream<Void>.makeStream()
        session.append(fixture.mix)
        await session.finish { _, _ in
            requested.continuation.yield(())
            requested.continuation.finish()
            if slow { try await Task.sleep(for: .seconds(30)) }
            throw SpeechKitError.relayRejected(kind: "operationNotAllowed")
        }
        for await _ in requested.stream { break }
        let original = DictationTranscript(text: "Every selected word.", model: "selected/model")
        let result = try await session.resolve(original)
        #expect(result.transcript.text == original.text)
        #expect(result.transcript.model == original.model)
        #expect(result.transcript.outcome?.path == .failed)
        await session.cancel()
    }

    @Test func cancelledDictationDoesNotDeliverText() async throws {
        let fixture = try await VoiceFixture(trusted: true)
        defer { fixture.cleanUp() }
        let session = DictationVoiceSession(check: fixture.check)
        session.append(fixture.mix)
        await session.cancel()
        await #expect(throws: CancellationError.self) {
            try await session.resolve(DictationTranscript(text: "Kept audio.", model: "selected/model"))
        }
    }

    @Test func captureKeepsThe24KilohertzProviderFeedAndAdds16KilohertzRecognition() async throws {
        let source = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 48_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData?[0])
        for n in 0..<48_000 { samples[n] = 0.2 * sin(Float(n) * 0.02) }
        let provider = Mutex(Data())
        let recognition = Mutex(Data())
        let sink = PCM16CaptureSink()
        var output = PCM16CaptureOutput(sampleRate: 24_000) { chunk in provider.withLock { $0.append(chunk) } }
        output.receiveRecognition = { chunk in recognition.withLock { $0.append(chunk) } }
        try await sink.begin(inputFormat: source, output: output)
        sink.consume(buffer)
        sink.finish()
        #expect(abs(provider.withLock { $0.count } - 48_000) < 200)
        #expect(abs(recognition.withLock { $0.count } - 32_000) < 200)
    }
}

struct VoiceFixture: Sendable {
    let directory: URL
    let owner: Data
    let mix: Data
    let phrases: [SpeakerPhrase]
    let check: VoiceCheck
    let store: VoiceProfileStore

    init(trusted: Bool, onFailure: @escaping @Sendable (VoiceFilterStage, any Error) -> Void = { _, _ in }) async throws {
        directory = URL.temporaryDirectory.appending(path: "dictation-voices-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bundle = Bundle(for: VoiceFixtureBundle.self)
        let ownURL = try #require(bundle.url(forResource: "speaker-owner", withExtension: "wav"))
        let otherURL = try #require(bundle.url(forResource: "speaker-other", withExtension: "wav"))
        owner = try await DictationVoiceProfiles.decode(ownURL)
        let other = try await DictationVoiceProfiles.decode(otherURL)
        let silence = Data(repeating: 0, count: 32_000)
        mix = owner + silence + other + silence
        let ownDuration = Duration.seconds(Double(owner.count) / 32_000)
        let otherStart = ownDuration + .seconds(1)
        phrases = [SpeakerPhrase(speaker: 0, text: "Only my words.", words: [.zero..<ownDuration]),
            SpeakerPhrase(speaker: 1, text: "Other voice.", words: [otherStart..<(otherStart + .seconds(Double(other.count) / 32_000))])]
        if trusted {
            let referenceURL = try #require(bundle.url(forResource: "speaker-reference", withExtension: "json"))
            let reference = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: referenceURL)) as? [String: Any])
            let embeddings = try #require(reference["embeddings"] as? [String: [Double]])
            let embedding = try #require(embeddings["en-developer-message"])
            let profile: [String: Any] = ["modelVersion": try #require(reference["modelVersion"] as? String),
                "createdAt": Date.now.timeIntervalSinceReferenceDate, "candidates": [],
                "exemplars": Array(repeating: ["values": embedding], count: 5), "recentMatches": Array(repeating: true, count: 10)]
            try JSONSerialization.data(withJSONObject: profile).write(to: directory.appending(path: "VoiceProfile.json"))
        }
        store = VoiceProfileStore(accountDirectory: directory)
        check = try VoiceCheck(profile: try await store.profile(), store: store, startedAt: .now, onFailure: onFailure)
    }

    func cleanUp() { store.retire(); try? FileManager.default.removeItem(at: directory) }
}

private final class VoiceFixtureBundle: NSObject {}

@MainActor
private final class VoiceFixtureRecorder: VoiceInputRecording {
    private(set) var recognitionWasAttached = false
    private let pcm: Data
    init(pcm: Data = Data(repeating: 0, count: 3_200)) { self.pcm = pcm }
    func ensurePermission() async throws {}
    func activateSession() async throws {}
    func deactivateSession() async throws {}
    func start(output: PCM16CaptureOutput) async throws {
        recognitionWasAttached = output.receiveRecognition != nil
        output.receive(pcm)
        output.receiveRecognition?(pcm)
    }
    func stop() {}
    func levels() -> AsyncStream<[Float]> { AsyncStream { $0.finish() } }
}

private final class InjectedVoiceTranscriber: TranscriptionService {
    let requestCount = Mutex(0)
    private let requested = AsyncStream<Void>.makeStream()
    let phrases: [SpeakerPhrase]
    let refused: Bool
    init(phrases: [SpeakerPhrase], refused: Bool) { self.phrases = phrases; self.refused = refused }
    func makeRealtimeTranscription(configuration: TranscriptionConfiguration) async throws -> RealtimeTranscription? { nil }
    @concurrent func transcribe(_ recording: DictationRecording<ExecutionTarget>, configuration: TranscriptionConfiguration) async throws -> DictationTranscript {
        for await _ in requested.stream { break }
        return DictationTranscript(text: "Selected provider text.", model: configuration.model.batchLibraryID)
    }
    @concurrent func speakerPhrases(_ pcm16: Data, configuration: TranscriptionConfiguration,
        uploadFinished: @escaping @Sendable (Duration) -> Void) async throws -> [SpeakerPhrase] {
        requestCount.withLock { $0 += 1 }
        requested.continuation.yield(())
        requested.continuation.finish()
        uploadFinished(.milliseconds(10))
        if refused { throw SpeechKitError.relayRejected(kind: "credentialsUnavailable") }
        return phrases
    }
}
