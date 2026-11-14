import AVFoundation
import Foundation
@testable import SpeakerRecognition
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
        let voices = DictationVoiceProfiles(defaults: defaults, directory: directory, history: { nil })
        let recorder = VoiceFixtureRecorder()
        let controller = VoiceInputController(access: .fixture, owner: ExecutionTarget(hostID: UUID()),
            transcriber: StubTranscriber(text: "Selected provider text."), recorder: recorder, recordings: recordings.store,
            voices: voices, configuration: { .init(model: .azureMAITranscribe2, language: .english, voiceChoice: .everyone) })
        controller.markRecordingRequested()
        try await controller.startAsync()
        try await controller.stopRecording()
        let result = try await controller.transcribe()
        #expect(result.transcript.text == "Selected provider text.")
        #expect(result.transcript.outcome == nil)
        #expect(!recorder.recognitionWasAttached)
    }

    @Test @MainActor func enablingOnlyMineReplaysOriginalsCompletedUnderEveryone() async throws {
        let name = "HistoryAfterEveryone.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = URL.temporaryDirectory.appending(path: name)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try #require(Bundle(for: VoiceFixtureBundle.self).url(forResource: "speaker-owner", withExtension: "wav"))
        let finishedAt = Date.now.addingTimeInterval(0.05)
        let recording = VoiceHistoryRecording(url: original, startedAt: finishedAt.addingTimeInterval(-6), finishedAt: finishedAt)
        let validated = Mutex(false)
        let voices = DictationVoiceProfiles(defaults: defaults, directory: directory, history: {
            DictationVoiceHistory(recordings: [recording], validate: { validated.withLock { $0 = true } })
        })
        voices.refresh(active: false)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "VoiceProfile.json").path))
        try await Task.sleep(for: .milliseconds(100))
        voices.refresh(active: true)
        voices.learnFromHistory()
        #expect(await waitUntil(timeout: .seconds(15)) { validated.withLock { $0 } })
        let profileURL = directory.appending(path: "VoiceProfile.json")
        #expect(try await waitUntil {
            guard let data = try? Data(contentsOf: profileURL),
                  let profile = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = profile["candidates"] as? [Any] else { return false }
            return !candidates.isEmpty
        })
    }

    @Test @MainActor func aSyncedForgetDateDeletesBothLocalTemplatesUnderEveryone() async throws {
        let first = try await VoiceFixture(trusted: true)
        let second = try await VoiceFixture(trusted: true)
        defer { first.cleanUp(); second.cleanUp() }
        let name = "SyncedVoiceForget.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let left = DictationVoiceProfiles(defaults: defaults, directory: first.directory, history: { nil })
        let right = DictationVoiceProfiles(defaults: defaults, directory: second.directory, history: { nil })
        left.refresh(active: true)
        right.refresh(active: true)
        #expect(await waitUntil { left.status(for: nil) == .learned && right.status(for: nil) == .learned })
        left.refresh(active: false)
        right.refresh(active: false)
        await left.forget()
        right.refresh(active: false)
        #expect(await waitUntil { !left.hasProfile && !right.hasProfile })
        #expect(left.status(for: nil) == .learning)
        #expect(right.status(for: nil) == .learning)
        #expect(!FileManager.default.fileExists(atPath: first.directory.appending(path: "VoiceProfile.json").path))
        #expect(!FileManager.default.fileExists(atPath: second.directory.appending(path: "VoiceProfile.json").path))
    }

    @Test @MainActor func transientFailuresKeepProfileStatusAndRefusalMarksTheRoute() async throws {
        let name = "VoiceStatus.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = URL.temporaryDirectory.appending(path: name)
        defer { try? FileManager.default.removeItem(at: directory) }
        let voices = DictationVoiceProfiles(defaults: defaults, directory: directory, history: { nil })
        let hostID = UUID()
        voices.failed(URLError(.timedOut), stage: .filter, hostID: hostID)
        #expect(voices.status(for: hostID) == .learning)
        voices.failed(SpeechKitError.invalidResponse, stage: .learning)
        #expect(voices.status(for: hostID) == .learning)
        voices.failed(SpeechKitError.httpFailure(statusCode: 403, body: ""), stage: .filter, hostID: hostID)
        #expect(voices.status(for: hostID) == .unavailable)
        #expect(voices.status(for: UUID()) == .learning)
        #expect(voices.status(for: nil) == .learning)
    }

    @Test(arguments: [false, true]) @MainActor func controllerUsesItsInjectedSpeakerRequest(refused: Bool) async throws {
        let fixture = try await VoiceFixture(trusted: true)
        defer { fixture.cleanUp() }
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let name = "InjectedVoice.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let voices = DictationVoiceProfiles(defaults: defaults, directory: fixture.directory, history: { nil })
        let transcriber = InjectedVoiceTranscriber(phrases: fixture.phrases, refused: refused, waitsForRequest: true)
        let hostID = UUID()
        let controller = VoiceInputController(access: .fixture, owner: ExecutionTarget(hostID: hostID),
            transcriber: transcriber, recorder: VoiceFixtureRecorder(pcm: fixture.mix), recordings: recordings.store,
            voices: voices, configuration: { .init(model: .elevenLabsScribeV2, language: .english, voiceChoice: .onlyMine) })
        controller.markRecordingRequested()
        try await controller.startAsync()
        try await controller.stopRecording()
        let result = try await controller.transcribe()
        #expect(result.transcript.everyone == "Selected provider text.")
        if refused {
            #expect(result.transcript.text == "Selected provider text.")
            #expect(result.transcript.outcome?.path == .failed)
            #expect(await waitUntil { voices.status(for: hostID) == .unavailable })
        } else {
            #expect(result.transcript.text == "Only my words.")
            #expect(result.transcript.model == TranscriptionModel.azureMAITranscribe2.batchLibraryID)
        }
        #expect(transcriber.requestCount.withLock { $0 } == 1)
    }

    @Test @MainActor func defaultsFollowTheResolvedModelUntilAnExplicitChoice() throws {
        let name = "DictationVoiceTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(TranscriptionConfiguration(model: .azureMAITranscribe2, language: .automatic).voices == .onlyMine)
        #expect(TranscriptionConfiguration(model: .elevenLabsScribeV2Realtime, language: .automatic).voices == .everyone)
        #expect(TranscriptionSettings.voiceChoice(defaults: defaults) == nil)
        TranscriptionSettings.setVoices(.onlyMine, defaults: defaults)
        #expect(TranscriptionSettings.voiceChoice(defaults: defaults) == .onlyMine)
        #expect(TranscriptionConfiguration(model: .elevenLabsScribeV2Realtime, language: .automatic,
            voiceChoice: TranscriptionSettings.voiceChoice(defaults: defaults)).voices == .onlyMine)
    }

    @Test @MainActor
    func anUntrustedControllerKeepsTextWithoutRequestingAzure() async throws {
        let fixture = try await VoiceFixture(trusted: false)
        defer { fixture.cleanUp() }
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let name = "UnchangedVoices.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let voices = DictationVoiceProfiles(defaults: defaults, directory: fixture.directory, history: { nil })
        let transcriber = InjectedVoiceTranscriber(phrases: fixture.phrases, refused: false, waitsForRequest: false)
        let controller = VoiceInputController(access: .fixture, owner: ExecutionTarget(hostID: UUID()),
            transcriber: transcriber, recorder: VoiceFixtureRecorder(pcm: fixture.owner), recordings: recordings.store,
            voices: voices, configuration: { .init(model: .elevenLabsScribeV2, language: .english, voiceChoice: .onlyMine) })
        controller.markRecordingRequested()
        try await controller.startAsync()
        try await controller.stopRecording()
        let result = try await controller.transcribe()
        #expect(result.transcript.text == "Selected provider text.")
        #expect(result.transcript.model == TranscriptionModel.elevenLabsScribeV2.batchLibraryID)
        #expect(transcriber.requestCount.withLock { $0 } == 0)
        #expect(try await recordings.listedIDs() == [result.recordingID])
    }

    @Test func thePreviouslyMissedBalancedMixRequestsLabels() async throws {
        let fixture = try await VoiceFixture(trusted: true)
        defer { fixture.cleanUp() }
        let session = DictationVoiceSession(state: .active(fixture.check))
        let requested = AsyncStream<Void>.makeStream()
        session.append(fixture.mix + fixture.mix)
        await session.finish { _, _ in
            requested.continuation.yield(())
            requested.continuation.finish()
            return fixture.phrases
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in requested.stream { break }; try Task.checkCancellation() }
            group.addTask { try await Task.sleep(for: .seconds(15)); throw URLError(.timedOut) }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
        let result = try await session.resolve(DictationTranscript(text: "Selected complete words.", model: "selected/model"))
        #expect(result.transcript.removedVoices)
        #expect(result.transcript.everyone == "Selected complete words.")
        await session.cancel()
    }

    @Test(arguments: [(TranscriptionModel.azureMAITranscribe2.libraryID, 1), (TranscriptionModel.azureMAITranscribe2.batchLibraryID, 1),
                      (TranscriptionModel.elevenLabsScribeV2.batchLibraryID, 0)])
    func onlyTheLabelledModelsLineBreakRequestsLabels(model: String, requests: Int) async throws {
        let fixture = try await VoiceFixture(trusted: true)
        defer { fixture.cleanUp() }
        let session = DictationVoiceSession(state: .active(fixture.check))
        let requested = Mutex(0)
        session.append(fixture.owner)
        await session.finish { _, _ in
            requested.withLock { $0 += 1 }
            return [fixture.phrases[0]]
        }
        await fixture.check.checking?.value
        #expect(requested.withLock { $0 } == 0)
        let original = DictationTranscript(text: "Only my words.\nOther voice.", model: model)
        let result = try await session.resolve(original)
        #expect(requested.withLock { $0 } == requests)
        #expect(result.transcript.outcome?.path == (requests == 1 ? .keptEveryone : .notHeard))
        #expect(result.transcript.text == original.text)
        await session.cancel()
    }

    @Test(arguments: [false, true])
    func refusalAndAnOverBudgetReplyKeepTheSelectedTranscript(slow: Bool) async throws {
        let fixture = try await VoiceFixture(trusted: true)
        defer { fixture.cleanUp() }
        let session = DictationVoiceSession(state: .active(fixture.check), budget: { _ in .milliseconds(5) })
        let requested = AsyncStream<Void>.makeStream()
        session.append(fixture.mix)
        await session.finish { _, _ in
            requested.continuation.yield(())
            requested.continuation.finish()
            if slow { try await Task.sleep(for: .seconds(30)) }
            throw SpeechKitError.httpFailure(statusCode: 403, body: "")
        }
        for await _ in requested.stream { break }
        let original = DictationTranscript(text: "Every selected word.", model: "selected/model")
        let started = ContinuousClock.now
        let result = try await session.resolve(original)
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(result.transcript.text == original.text)
        #expect(result.transcript.model == original.model)
        #expect(result.transcript.outcome?.path == .failed)
        await session.cancel()
    }

    @Test func conversionFailureKeepsTheOrdinaryTranscriptAndItsCause() async throws {
        let fixture = try await VoiceFixture(trusted: true)
        defer { fixture.cleanUp() }
        let session = DictationVoiceSession(state: .active(fixture.check))
        session.append(fixture.mix)
        session.invalidate(NSError(domain: "synthetic-audio", code: 17))
        await session.finish { _, _ in Issue.record("An incomplete recognition stream must not be uploaded"); return [] }
        let original = DictationTranscript(text: "Selected complete words.", model: "selected/model")
        let result = try await session.resolve(original)
        #expect(result.transcript.text == original.text)
        #expect(result.transcript.outcome?.path == .failed)
        switch result.check {
        case .failure(let error):
            #expect((error as NSError).domain == "synthetic-audio")
            #expect((error as NSError).code == 17)
        case .success, nil: Issue.record("The capture failure must retain its cause")
        }
        await session.cancel()
    }

    @Test @MainActor func cancelledControllerRetainsRecordingWithoutDeliveringText() async throws {
        let fixture = try await VoiceFixture(trusted: true)
        defer { fixture.cleanUp() }
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let name = "CancelledVoices.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let voices = DictationVoiceProfiles(defaults: defaults, directory: fixture.directory, history: { nil })
        let transcriber = InjectedVoiceTranscriber(phrases: fixture.phrases, refused: false, waitsForRequest: true, labelledDelay: .seconds(30))
        let controller = VoiceInputController(access: .fixture, owner: ExecutionTarget(hostID: UUID()),
            transcriber: transcriber, recorder: VoiceFixtureRecorder(pcm: fixture.mix), recordings: recordings.store,
            voices: voices, configuration: { .init(model: .elevenLabsScribeV2, language: .english, voiceChoice: .onlyMine) })
        controller.markRecordingRequested()
        try await controller.startAsync()
        try await controller.stopRecording()
        let delivery = Task { try await controller.transcribe() }
        #expect(await waitUntil { transcriber.requestCount.withLock { $0 } == 1 })
        delivery.cancel()
        await #expect(throws: CancellationError.self) { try await delivery.value }
        #expect(try await recordings.listedIDs().count == 1)
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
    let waitsForRequest: Bool
    let labelledDelay: Duration
    init(phrases: [SpeakerPhrase], refused: Bool, waitsForRequest: Bool, labelledDelay: Duration = .zero) {
        self.phrases = phrases
        self.refused = refused
        self.waitsForRequest = waitsForRequest
        self.labelledDelay = labelledDelay
    }
    func makeRealtimeTranscription(configuration: TranscriptionConfiguration) async throws -> RealtimeTranscription? { nil }
    @concurrent func transcribe(_ recording: DictationRecording<ExecutionTarget>, configuration: TranscriptionConfiguration) async throws -> DictationTranscript {
        if waitsForRequest { for await _ in requested.stream { break } }
        return DictationTranscript(text: "Selected provider text.", model: configuration.model.batchLibraryID)
    }
    @concurrent func speakerPhrases(_ pcm16: Data, configuration: TranscriptionConfiguration,
        uploadFinished: @escaping @Sendable (Duration) -> Void) async throws -> [SpeakerPhrase] {
        requestCount.withLock { $0 += 1 }
        requested.continuation.yield(())
        requested.continuation.finish()
        uploadFinished(.milliseconds(10))
        if refused { throw SpeechKitError.httpFailure(statusCode: 403, body: "") }
        if labelledDelay > .zero { try await Task.sleep(for: labelledDelay) }
        return phrases
    }
}
