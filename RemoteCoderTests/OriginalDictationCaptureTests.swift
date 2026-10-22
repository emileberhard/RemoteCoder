import AVFoundation
import DictationLibrary
import Foundation
import SpeechKit
import Synchronization
import Testing
@testable import RemoteCoder

struct OriginalDictationCaptureTests {
    @Test @MainActor func aFlushedDraftReceiptDoesNotDiscardTheArchivalOriginal() async throws {
        let fixture = await WorkspaceFixture()
        defer { await fixture.cleanUp() }
        let recordings = try TemporaryDictationRecordings()
        defer { recordings.cleanUp() }
        let directory = URL.temporaryDirectory.appending(path: "original-dictation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let seal = OriginalFinalizationGate()
        let library = SharedDictationLibrary(defaults: fixture.defaults, directory: directory) { writer in
            await seal.wait()
            _ = try await writer.finish()
        }
        library.isEnabled = true
        library.cancelPublication()
        defer { library.cancelPublication(); await seal.release(); await library.finishPendingCaptures() }
        let screen = try #require(fixture.workspace.selectedScreen)
        try #require(await screen.prepareDraft())
        let transcriber = ArchiveFixtureTranscriber()
        screen.target.voice = VoiceInputController(access: .fixture, owner: screen.executionTarget,
            transcriber: transcriber, recorder: NativeFixtureVoiceRecorder(), recordings: recordings.store, library: library)
        screen.micTapStart()
        await screen.micTapStartAsync()
        library.isEnabled = false
        screen.micTapStopImmediate()
        await screen.micTapStopAsync()
        #expect(screen.target.voiceError == nil)
        #expect(screen.input == "Synthetic archival dictation")
        let id = try #require(transcriber.recordingIDs.first)
        #expect(try await screen.drafts.hasSavedReceipt(for: id))
        #expect(try await recordings.listedIDs().isEmpty)
        await seal.waitUntilStarted()
        await seal.release()
        await library.finishPendingCaptures()
        let container = try #require(Bundle.main.object(forInfoDictionaryKey: "RemoteCoderDictationContainer") as? String)
        let archive = try DictationLibraryStore(directory: directory, source: "fixture-inspection", capacityBytes: 536_870_912,
                                               containerIdentifier: container)
        let retained = try #require(try await archive.heldCaptures().first { $0.id == id })
        let original = try #require(retained.originalURL)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(retained.capture.sampleRate == 48_000)
    }

    @Test func archivalSinkReceivesMicrophoneRateBeforeProviderResampling() async throws {
        let native = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: native, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<4_800 { samples[index] = Float(sin(Double(index) * 0.1)) * 0.25 }
        let observed = Mutex<(configured: Bool, originalFrames: Int, providerBytes: Int, orderValid: Bool)>((false, 0, 0, true))
        var output = PCM16CaptureOutput(sampleRate: 16_000) { bytes in
            observed.withLock {
                $0.orderValid = $0.orderValid && $0.originalFrames == 4_800
                $0.providerBytes += bytes.count
            }
        }
        output.configureOriginal = { format in
            #expect(format.sampleRate == 48_000)
            observed.withLock { $0.configured = true }
        }
        output.receiveOriginal = { buffer in
            #expect(buffer.format.sampleRate == 48_000)
            observed.withLock {
                $0.orderValid = $0.orderValid && $0.configured
                $0.originalFrames += Int(buffer.frameLength)
            }
        }
        let sink = PCM16CaptureSink()
        try await sink.begin(inputFormat: native, output: output)
        sink.consume(buffer)
        sink.finish()
        let result = observed.withLock { $0 }
        #expect(result.originalFrames == 4_800)
        #expect(result.providerBytes > 0 && result.providerBytes <= 3_200)
        #expect(result.orderValid)
        sink.consume(buffer)
        #expect(observed.withLock { $0.originalFrames } == 4_800)
    }
}

@MainActor
private final class NativeFixtureVoiceRecorder: VoiceInputRecording {
    private let sink = PCM16CaptureSink()

    func ensurePermission() async throws {}
    func activateSession() async throws {}
    func deactivateSession() async throws {}
    func start(output: PCM16CaptureOutput) async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<4_800 { samples[index] = Float(sin(Double(index) * 0.1)) * 0.25 }
        try await sink.begin(inputFormat: format, output: output)
        sink.consume(buffer)
    }
    func stop() { sink.finish() }
    func normalizedLevel() -> Float { 0 }
}

private final class ArchiveFixtureTranscriber: TranscriptionService {
    private let recorded = Mutex<[UUID]>([])
    var recordingIDs: [UUID] { recorded.withLock { $0 } }

    func makeRealtimeTranscription(configuration: TranscriptionConfiguration) async throws -> RealtimeTranscription? { nil }

    @concurrent func transcribe(_ recording: DictationRecording<ExecutionTarget>, configuration: TranscriptionConfiguration) async throws -> String {
        _ = try await recording.transcriptionAudio(maximumByteCount: 1_000_000)
        recorded.withLock { $0.append(recording.id) }
        return "Synthetic archival dictation"
    }
}

private actor OriginalFinalizationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var started: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0; started?.resume(); started = nil }
    }

    func waitUntilStarted() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
