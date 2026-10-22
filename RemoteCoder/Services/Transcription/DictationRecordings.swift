import Foundation
import OSLog
import SpeechKit

private let appDictationRecordingStore: DictationRecordingStore<ExecutionTarget> = {
    DictationRecordingStore<ExecutionTarget>.located(in: .live)
}()

extension DictationRecordingStore where Owner == ExecutionTarget {
    static func located(in storage: HostStorage) -> DictationRecordingStore<ExecutionTarget> {
        do {
            return DictationRecordingStore(
                directory: storage.directory(for: .device).appending(path: "dictation-recordings"),
                retention: try DictationRecordingRetention(
                    maximumCount: 5,
                    maximumAge: DictationRecordingStore<ExecutionTarget>.maximumAge
                )
            )
        } catch {
            preconditionFailure(error.localizedDescription)
        }
    }

    static var app: DictationRecordingStore<ExecutionTarget> { appDictationRecordingStore }
    static var maximumAge: Duration { .seconds(7 * 24 * 60 * 60) }

    func closeAfterFailedStart(_ writer: DictationRecordingWriter<ExecutionTarget>) async {
        do {
            let recording = try await writer.finish()
            guard recording.duration == .zero else { return }
            try await discard(recording)
        } catch {
            guard !(error is IncompleteDictationRecording<ExecutionTarget>) else { return }
            Logger(subsystem: "RemoteCoder", category: "VoiceInput.Recording")
                .error("dictation recording could not be closed after a failed start: \(error.localizedDescription, privacy: .public)")
        }
    }
}

struct Dictation: Sendable {
    let text: String
    let recordingID: UUID
    let recording: DictationRecording<ExecutionTarget>?
}

enum DictationError: LocalizedError {
    case noActiveRecording
    case noStoppedRecording
    case recordingNotSaved(any Error)
    case notAddedToDraft(any Error)

    var errorDescription: String? {
        switch self {
        case .noActiveRecording: "There is no active recording."
        case .noStoppedRecording: "There is no recording to transcribe."
        case .recordingNotSaved(let error): "The recording could not be saved: \(error.localizedDescription)"
        case .notAddedToDraft(let error): "Could not add the dictation: \(error.localizedDescription)"
        }
    }
}

struct RecoverableDictation: Identifiable {
    enum Status: Equatable {
        case waiting
        case transcribing
        case failed(String)
    }

    let recording: DictationRecording<ExecutionTarget>
    var status: Status

    var id: UUID { recording.id }
}
