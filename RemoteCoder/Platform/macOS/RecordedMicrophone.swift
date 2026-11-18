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
    func stop() {}
    func levels() -> AsyncStream<[Float]> { AsyncStream { $0.finish() } }

    @concurrent
    private static func feed(url: URL, sink: PCM16CaptureSink, output: PCM16CaptureOutput) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        let header = try handle.read(upToCount: 12)
        try handle.close()
        guard let header, header.count == 12,
              header.prefix(4) == Data("RIFF".utf8),
              header.suffix(4) == Data("WAVE".utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let file = try AVAudioFile(forReading: url)
        let source = file.fileFormat.streamDescription.pointee
        guard source.mFormatID == kAudioFormatLinearPCM,
              source.mBitsPerChannel == 16,
              source.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
              source.mFormatFlags & kAudioFormatFlagIsFloat == 0,
              file.fileFormat.sampleRate == Double(GatewayFileDownloadSource.dictationSampleRate),
              file.fileFormat.channelCount == 1,
              file.processingFormat.sampleRate == Double(GatewayFileDownloadSource.dictationSampleRate),
              file.processingFormat.channelCount == 1,
              file.length > 0,
              file.length <= GatewayFileDownloadSource.maximumDictationDurationSeconds * GatewayFileDownloadSource.dictationSampleRate else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try await sink.begin(inputFormat: file.processingFormat, output: output)
        defer { sink.finish() }
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
