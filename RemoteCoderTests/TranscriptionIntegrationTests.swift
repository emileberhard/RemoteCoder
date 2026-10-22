import AVFoundation
import DictationLibrary
import Foundation
import Synchronization
import SpeechKit
import Testing
@testable import RemoteCoder

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RUN_REMOTE_CODER_TRANSCRIPTION_INTEGRATION_TESTS"] == "1"), .timeLimit(.minutes(5)))
struct TranscriptionIntegrationTests {
    @Test func batchServiceTranscribesSavedAudioWithPersonalVocabulary() async throws {
        let access = try gatewayAccess()
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let writer = try await recordings.store.startRecording(owner: ExecutionTarget(hostID: access.host.id), sampleRate: 16_000)
        writer.append(try fixturePCM())
        let recording = try await writer.finish()
        let configuration = TranscriptionConfiguration(model: .openAIGPT4oMini, language: .english,
                                                       customVocabulary: ["OpenAI", "AssemblyAI", "ElevenLabs"])
        let text = try await RemoteCoderTranscriptionService(access: access).transcribe(recording, configuration: configuration)
        assertAnchors(text)
        #expect(try await recordings.listedIDs() == [recording.id])
    }

    @Test func elevenLabsFactoryFinalizesSavedAudioWithPersonalVocabulary() async throws {
        try await realtimeFactoryFinalizesSavedAudioWithPersonalVocabulary(model: .elevenLabsScribeV2Realtime)
    }

    @Test func openAIFactoryFinalizesSavedAudioWithPersonalVocabulary() async throws {
        try await realtimeFactoryFinalizesSavedAudioWithPersonalVocabulary(model: .openAIGPT4oTranscribeRealtime)
    }

    @Test func geminiFactoryFinalizesSavedAudioWithPersonalVocabulary() async throws {
        try await realtimeFactoryFinalizesSavedAudioWithPersonalVocabulary(model: .gemini35TranscribeLiveSmart)
    }

    @Test func assemblyAIFactoryFinalizesSavedAudioWithPersonalVocabulary() async throws {
        try await realtimeFactoryFinalizesSavedAudioWithPersonalVocabulary(model: .assemblyAIUniversal35ProRealtime)
    }

    @Test func azureFactoryFinalizesSavedAudioWithPersonalVocabulary() async throws {
        try await realtimeFactoryFinalizesSavedAudioWithPersonalVocabulary(model: .azureMAITranscribe2)
    }

    private func realtimeFactoryFinalizesSavedAudioWithPersonalVocabulary(model: TranscriptionModel) async throws {
        let access = try gatewayAccess()
        let service = RemoteCoderTranscriptionService(access: access)
        let configuration = TranscriptionConfiguration(model: model, language: .englishAndSwedish,
            customVocabulary: ["OpenAI", "AssemblyAI", "ElevenLabs", String(repeating: "x", count: 51)] + (0..<101).map { "Term\($0)" })
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let original = try fixturePCM()
        let realtime = try #require(try await service.makeRealtimeTranscription(configuration: configuration))
        let pcm = try await providerPCM(original, sampleRate: realtime.session.sampleRate)
        let dictation = RealtimeDictation(session: realtime.session)
        do {
            let writer = try await recordings.store.startRecording(owner: ExecutionTarget(hostID: access.host.id), sampleRate: realtime.session.sampleRate)
            let chunkSize = realtime.session.sampleRate / 10 * 2
            for offset in stride(from: 0, to: pcm.count, by: chunkSize) {
                let chunk = pcm.subdata(in: offset..<min(offset + chunkSize, pcm.count))
                writer.append(chunk)
                dictation.append(chunk)
                try await Task.sleep(for: .milliseconds(100))
            }
            let recording = try await writer.finish()
            let text = try await dictation.finish()
            assertAnchors(text)
            #expect(try await recordings.listedIDs() == [recording.id])
        } catch {
            await dictation.cancel()
            throw error
        }
    }

    @Test func commonCleanupUsesChatContextAndPreservesDictionaryTerms() async throws {
        let access = try gatewayAccess()
        let profile = DictationProfile(archiveEnabled: true, preferredModel: "fixture", languages: ["en", "sv"],
            dictionary: ["OpenAI", "AssemblyAI", "ElevenLabs"], cleanupEnabled: true,
            outputLanguage: nil, thinkingLevel: "minimal")
        let plan = DictationPlan(unverifiedProfile: profile, context: .chat,
            capabilities: try DictationCapabilities(models: ["fixture"], fallbackModel: "fixture", supportsCleanup: true))
        let result = try await DictationCleanup.clean(text: "Um, send a message to OpenAI about AssemblyAI and ElevenLabs.",
            plan: plan, access: try await access.access(to: .gemini))
        assertAnchors(result.text)
        #expect(result.kind == .cleanup)
    }

    @Test @MainActor func azureStopToComposerLatencyWithAndWithoutArchiving() async throws {
        let access = try gatewayAccess()
        let pcm = try fixturePCM()
        for archived in [false, true, false, true] {
            let fixture = await WorkspaceFixture()
            defer { await fixture.cleanUp() }
            let recordings = try TemporaryDictationRecordings()
            defer { recordings.cleanUp() }
            let directory = URL.temporaryDirectory.appending(path: "azure-stop-latency-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let library = SharedDictationLibrary(defaults: fixture.defaults, directory: directory)
            library.isEnabled = archived
            library.cancelPublication()
            defer { library.cancelPublication(); await library.finishPendingCaptures() }
            let screen = try #require(fixture.workspace.selectedScreen)
            try #require(await screen.prepareDraft())
            let recorder = ProgressiveFixtureRecorder()
            let transcriber = AzureTimingTranscriber(access: access)
            screen.target.voice = VoiceInputController(access: access, owner: screen.executionTarget,
                transcriber: transcriber, recorder: recorder, recordings: recordings.store, library: library,
                configuration: { TranscriptionConfiguration(model: .azureMAITranscribe2, language: .englishAndSwedish) })
            screen.micTapStart()
            await screen.micTapStartAsync()
            try #require(screen.target.voice.isRecording)
            try await recorder.feed(pcm)
            library.isEnabled = false
            let start = ContinuousClock.now
            screen.micTapStopImmediate()
            await screen.micTapStopAsync()
            let elapsed = start.duration(to: .now)
            #expect(screen.target.voiceError == nil)
            #expect(transcriber.models == [.azureMAITranscribe2])
            assertAnchors(screen.input)
            print("Azure stop-to-composer archived=\(archived) elapsed=\(elapsed)")
        }
    }

    private func gatewayAccess() throws -> GatewaySpeechAccess {
        let configuration = try LocalConfiguration.load()
        let host = GatewayHostConfiguration(id: UUID(), name: "Live transcription test",
            hostname: try #require(configuration.macMiniHostname, "Missing configured gateway host"),
            port: try #require(configuration.codexGatewayPort, "Missing configured gateway port"),
            authToken: try #require(configuration.codexGatewayAuthToken, "Missing configured gateway credential"),
            transport: .trustedNetwork)
        return GatewaySpeechAccess(host: host, routes: .isolated(host))
    }

    private func providerPCM(_ pcm: Data, sampleRate: Int) async throws -> Data {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(pcm.count / 2)))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.int16ChannelData?[0])
        _ = pcm.copyBytes(to: UnsafeMutableRawBufferPointer(start: samples, count: pcm.count))
        let output = Mutex(Data())
        let sink = PCM16CaptureSink()
        try await sink.begin(inputFormat: format, output: PCM16CaptureOutput(sampleRate: sampleRate) { bytes in
            output.withLock { $0.append(bytes) }
        })
        sink.consume(buffer)
        sink.finish()
        return output.withLock { $0 }
    }

    private func fixturePCM() throws -> Data {
        let bundle = Bundle(for: FixtureBundle.self)
        let url = try #require(bundle.url(forResource: "providers", withExtension: "pcm"))
        return try Data(contentsOf: url)
    }

    private func assertAnchors(_ text: String) {
        let normalized = text.lowercased().filter(\.isLetter)
        #expect(["openai", "assemblyai", "elevenlabs"].filter { normalized.contains($0) }.count >= 2,
                "Expected at least two synthetic fixture provider names")
    }
}

private final class FixtureBundle: NSObject {}

@MainActor
private final class ProgressiveFixtureRecorder: VoiceInputRecording {
    private let sink = PCM16CaptureSink()
    private var format: AVAudioFormat?

    func ensurePermission() async throws {}
    func activateSession() async throws {}
    func deactivateSession() async throws {}
    func start(output: PCM16CaptureOutput) async throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        self.format = format
        try await sink.begin(inputFormat: format, output: output)
    }
    func feed(_ pcm: Data) async throws {
        let format = try #require(format)
        for offset in stride(from: 0, to: pcm.count, by: 3_200) {
            let bytes = pcm.subdata(in: offset..<min(offset + 3_200, pcm.count))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(bytes.count / 2)))
            buffer.frameLength = buffer.frameCapacity
            let samples = try #require(buffer.int16ChannelData?[0])
            _ = bytes.copyBytes(to: UnsafeMutableRawBufferPointer(start: samples, count: bytes.count))
            sink.consume(buffer)
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    func stop() { sink.finish() }
    func normalizedLevel() -> Float { 0 }
}

private final class AzureTimingTranscriber: TranscriptionService {
    private let service: RemoteCoderTranscriptionService
    private let observed = Mutex<[TranscriptionModel]>([])
    var models: [TranscriptionModel] { observed.withLock { $0 } }

    init(access: GatewaySpeechAccess) { service = RemoteCoderTranscriptionService(access: access) }

    func makeRealtimeTranscription(configuration: TranscriptionConfiguration) async throws -> RealtimeTranscription? {
        observed.withLock { $0.append(configuration.model) }
        return try await service.makeRealtimeTranscription(configuration: configuration)
    }

    @concurrent func transcribe(_ recording: DictationRecording<ExecutionTarget>, configuration: TranscriptionConfiguration) async throws -> String {
        try await service.transcribe(recording, configuration: configuration)
    }
}
