import Foundation
import AVFoundation

final class AudioLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var averagePowerDecibels: Float = -160

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?.pointee else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        var sum: Float = 0
        for index in 0..<frameCount {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameCount))
        let decibels = rms > 0 ? 20 * log10(rms) : -160

        lock.lock()
        averagePowerDecibels = max(-160, min(0, decibels))
        lock.unlock()
    }

    func readAveragePowerDecibels() -> Float {
        lock.lock()
        defer { lock.unlock() }
        return averagePowerDecibels
    }
}

private enum PCM16CaptureSinkError: LocalizedError {
    case formatUnavailable

    var errorDescription: String? {
        "Could not configure microphone audio."
    }
}

/// Where live microphone audio goes while recording: PCM16 mono at the rate
/// the recording and any realtime transport expect, delivered in ~100 ms chunks.
struct PCM16CaptureOutput: Sendable {
    let sampleRate: Int
    let receive: @Sendable (Data) -> Void
    var configureOriginal: (@Sendable (AVAudioFormat) throws -> Void)? = nil
    var receiveOriginal: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil
}

final class PCM16CaptureSink: @unchecked Sendable {
    private let lock = NSLock()
    private var processor: PCM16AudioProcessor?
    private var receiveOriginal: (@Sendable (AVAudioPCMBuffer) -> Void)?

    @concurrent func begin(inputFormat: AVAudioFormat, output: PCM16CaptureOutput) async throws {
        try lock.withLock {
            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(output.sampleRate),
                channels: 1,
                interleaved: true
            ), let processor = PCM16AudioProcessor(
                inputFormat: inputFormat,
                targetFormat: targetFormat,
                output: output.receive
            ) else {
                throw PCM16CaptureSinkError.formatUnavailable
            }
            try output.configureOriginal?(inputFormat)
            self.processor = processor
            receiveOriginal = output.receiveOriginal
        }
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        receiveOriginal?(buffer)
        processor?.ingest(buffer)
    }

    func finish() {
        lock.lock()
        processor?.finish()
        processor = nil
        receiveOriginal = nil
        lock.unlock()
    }
}

private final class PCM16AudioProcessor {
    private static let chunkDuration = 0.1

    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private let chunkByteCount: Int
    private let output: @Sendable (Data) -> Void
    private var pendingData = Data()

    init?(
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        output: @escaping @Sendable (Data) -> Void
    ) {
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            return nil
        }
        self.converter = converter
        self.targetFormat = targetFormat
        self.chunkByteCount = Int(targetFormat.sampleRate * Self.chunkDuration) * MemoryLayout<Int16>.size
        self.output = output
    }

    func ingest(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else {
            return
        }

        nonisolated(unsafe) var suppliedInput = false
        nonisolated(unsafe) let inputBuffer = buffer
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outputStatus in
            if unsafe suppliedInput {
                unsafe outputStatus.pointee = .noDataNow
                return nil
            }
            unsafe suppliedInput = true
            unsafe outputStatus.pointee = .haveData
            return unsafe inputBuffer
        }
        guard status != .error,
              converted.frameLength > 0,
              let channelData = converted.int16ChannelData
        else {
            return
        }

        pendingData.append(
            Data(
                bytes: channelData[0],
                count: Int(converted.frameLength) * MemoryLayout<Int16>.size
            )
        )
        while pendingData.count >= chunkByteCount {
            output(Data(pendingData.prefix(chunkByteCount)))
            pendingData.removeFirst(chunkByteCount)
        }
    }

    func finish() {
        guard !pendingData.isEmpty else { return }
        output(pendingData)
        pendingData.removeAll(keepingCapacity: false)
    }
}
