#if os(macOS)
import AVFoundation
import Foundation

@MainActor
final class RecordedMicrophone: VoiceInputRecording {
    private let url: URL
    private let sink = PCM16CaptureSink()

    init(url: URL) { self.url = url }
    func ensurePermission() async throws {}
    func activateSession() async throws {}
    func deactivateSession() async throws {}
    func start(output: PCM16CaptureOutput) async throws {
        try await Self.feed(url: url, sink: sink, output: output)
    }
    func stop() { sink.finish() }
    func levels() -> AsyncStream<[Float]> { AsyncStream { $0.finish() } }

    @concurrent
    private static func feed(url: URL, sink: PCM16CaptureSink, output: PCM16CaptureOutput) async throws {
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate == Double(GatewayFileDownloadSource.dictationSampleRate),
              file.processingFormat.channelCount == 1,
              file.length > 0,
              file.length <= GatewayFileDownloadSource.maximumDictationDurationSeconds * GatewayFileDownloadSource.dictationSampleRate else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try await sink.begin(inputFormat: file.processingFormat, output: output)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
            sink.consume(buffer)
        }
    }
}
#endif
