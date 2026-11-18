#if os(macOS)
import Foundation
import SpeechKit

private struct BatchTranscriptionService: TranscriptionService {
    let base: any TranscriptionService

    func makeRealtimeTranscription(configuration: TranscriptionConfiguration) async throws -> RealtimeTranscription? { nil }

    @concurrent func speakerPhrases(_ pcm16: Data, configuration: TranscriptionConfiguration,
        uploadFinished: @escaping @Sendable (Duration) -> Void) async throws -> [SpeakerPhrase] {
        try await base.speakerPhrases(pcm16, configuration: configuration, uploadFinished: uploadFinished)
    }

    @concurrent func transcribe(_ recording: DictationRecording<ExecutionTarget>, configuration: TranscriptionConfiguration) async throws -> DictationTranscript {
        try await base.transcribe(recording, configuration: configuration)
    }
}

@MainActor
final class BrowserDictationService {
    private let downloader: GatewayFileDownloadClient
    private let access: GatewaySpeechAccess
    private let owner: ExecutionTarget
    private let library: SharedDictationLibrary?
    private let voices: DictationVoiceProfiles
    private let defaults: UserDefaults
    private let directory: URL
    private let logger = AppLogger(category: "BrowserDictation")

    init(host: GatewayHostConfiguration, routes: GatewayRoutes, access: GatewaySpeechAccess,
         storage: HostStorage, library: SharedDictationLibrary?, voices: DictationVoiceProfiles, defaults: UserDefaults) {
        downloader = GatewayFileDownloadClient(host: host, routes: routes)
        self.access = access
        owner = ExecutionTarget(hostID: host.id)
        self.library = library
        self.voices = voices
        self.defaults = defaults
        directory = storage.directory(for: .device).appending(path: "browser-dictation", directoryHint: .isDirectory)
    }

    func execute(_ request: BrowserDictationRequest) async throws -> BrowserDictationOutput {
        try await Self.sweep(directory)
        let work = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try await Self.prepare(work)
        defer {
            do { try await Self.remove(work) }
            catch { logger.error("Browser dictation upload cleanup failed: \(error.localizedDescription)") }
        }
        let recordings = DictationRecordingStore<ExecutionTarget>(directory: work.appending(path: "recordings", directoryHint: .isDirectory),
            retention: try DictationRecordingRetention(maximumCount: 5, maximumAge: .seconds(24 * 60 * 60)))
        let downloaded = try await downloader.download(source: .dictation(path: request.path), knownRevision: nil,
            to: work, progress: { _ in }, admit: { _ in })
        guard case .downloaded(_, let file) = downloaded else { throw CocoaError(.fileReadUnknown) }
        let controller = VoiceInputController(access: access, owner: owner,
            transcriber: BatchTranscriptionService(base: RemoteCoderTranscriptionService(access: access)),
            recorder: RecordedMicrophone(url: file), recordings: recordings, library: library,
            voices: voices, configuration: { [defaults] in .current(defaults: defaults) })
        do {
            return try await withTaskCancellationHandler {
                try await controller.startAsync()
                try Task.checkCancellation()
                try await controller.stopRecording()
                try Task.checkCancellation()
                let result = try await controller.transcribe()
                if let recording = result.recording { await controller.discard(recording) }
                return BrowserDictationOutput(text: result.transcript.text, model: result.transcript.model)
            } onCancel: {
                Task { @MainActor in controller.beginQuiescing() }
            }
        } catch {
            try? await controller.quiesceForTermination()
            throw error
        }
    }

    @concurrent private static func prepare(_ directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @concurrent private static func sweep(_ directory: URL) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        for entry in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try manager.removeItem(at: entry)
        }
    }

    @concurrent private static func remove(_ directory: URL) async throws {
        try FileManager.default.removeItem(at: directory)
    }
}
#endif
