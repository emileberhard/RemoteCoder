import Foundation
import Observation
import OSLog
import SpeechKit

@MainActor
protocol DictationHost: AnyObject {
    var voice: VoiceInputController { get }
    func dictationFailed(_ message: String)
}

@MainActor
@Observable
final class DictationSession {
    private enum OwnedTask: Hashable {
        case finish, handOff, refresh
        case recovery(UUID)
    }

    private(set) var recoverable: [RecoverableDictation] = []
    @ObservationIgnored private var captureDraft: ComposerDraft?
    @ObservationIgnored private var deleting: Set<UUID> = []
    @ObservationIgnored private var isRetired = false
    @ObservationIgnored private let ownedTasks = OwnedTasks<OwnedTask>()
    @ObservationIgnored private weak var host: (any DictationHost)?
    @ObservationIgnored private let drafts: ComposerDraftStore
    @ObservationIgnored private let logger = Logger(subsystem: "RemoteCoder", category: "DictationSession")

    init(host: any DictationHost, drafts: ComposerDraftStore) {
        self.host = host
        self.drafts = drafts
    }

    func beginCapture(into draft: ComposerDraft?) {
        guard drafts.acceptsInput, !isRetired else { return }
        captureDraft = draft
        host?.voice.markRecordingRequested()
    }

    func finish(feedback: ((HapticEvent) -> Void)? = nil) async {
        guard drafts.acceptsInput, !isRetired else { return }
        let task = ownedTasks.start(.finish) { [weak self] in await self?.finishCapture(feedback: feedback) }
        await task.value
    }

    private func finishCapture(feedback: ((HapticEvent) -> Void)?) async {
        guard let voice = host?.voice else { return }
        let draft = captureDraft
        captureDraft = nil
        do {
            try await voice.stopRecording(onCaptureEnded: { feedback?(.commit) })
            let dictation = try await voice.transcribe()
            if !isRetired, let draft {
                try await receive(dictation.text, recordingID: dictation.recordingID, recording: dictation.recording, into: draft)
            }
        } catch {
            voice.markTranscriptionEnded()
            if !(error is CancellationError) {
                host?.dictationFailed(error.localizedDescription)
                feedback?(.error)
            }
            refreshRecoverable()
        }
    }

    /// The microphone is one device-wide resource. A target that leaves the screen
    /// must not keep recording where nobody can see it, and the audio it already
    /// captured belongs in its own draft, so the hand-off completes the
    /// dictation instead of discarding it or leaving the recorder running for the
    /// next host to fight over.
    func finishForHandOff() {
        guard let voice = host?.voice, voice.isRecording else { return }
        voice.markStopRequested()
        ownedTasks.start(.handOff) { [weak self] in
            await self?.finish()
        }
    }

    func refreshRecoverable() {
        guard !isRetired, drafts.acceptsInput else { return }
        ownedTasks.start(.refresh) { [weak self] in
            guard let voice = self?.host?.voice else { return }
            let saved: [DictationRecording<ExecutionTarget>]
            do { saved = try await voice.savedRecordings() }
            catch {
                self?.logger.error("saved dictations could not be listed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard let self, !Task.isCancelled, !self.isRetired, self.host?.voice === voice else { return }
            await self.apply(saved, voice: voice)
        }
    }

    func transcribe(_ id: UUID, into draft: ComposerDraft, feedback: @escaping (HapticEvent) -> Void) {
        guard !isRetired, drafts.acceptsInput, let index = recoverable.firstIndex(where: { $0.id == id }),
              recoverable[index].status != .transcribing else { return }
        recoverable[index].status = .transcribing
        let recording = recoverable[index].recording
        ownedTasks.start(.recovery(id)) { [weak self] in
            guard let voice = self?.host?.voice else { return }
            do {
                let text = try await voice.transcribe(recording)
                guard let self, !Task.isCancelled, !self.isRetired else { return }
                do {
                    try await self.receive(text, recordingID: recording.id, recording: recording, into: draft)
                    feedback(.success)
                } catch {
                    self.recoveryFailed(id, error: error, feedback: feedback)
                }
            } catch {
                guard let self, !Task.isCancelled, !self.isRetired else { return }
                self.recoveryFailed(id, error: error, feedback: feedback)
            }
        }
    }

    func delete(_ id: UUID, feedback: (HapticEvent) -> Void) {
        guard !isRetired, drafts.acceptsInput, let index = recoverable.firstIndex(where: { $0.id == id }),
              recoverable[index].status != .transcribing else { return }
        let recording = recoverable.remove(at: index).recording
        feedback(.commit)
        deleting.insert(id)
        ownedTasks.start(.recovery(id)) { [weak self] in
            guard let voice = self?.host?.voice else { return }
            await voice.discard(recording)
            guard let self, !self.isRetired else { return }
            self.deleting.remove(id)
            self.refreshRecoverable()
        }
    }

    func beginQuiescing() { ownedTasks.quiesce() }

    func finishQuiescing() async -> String? {
        await ownedTasks.drain()
        var failure: String?
        do { try await host?.voice.quiesceForTermination() }
        catch { failure = error.localizedDescription }
        captureDraft = nil
        return failure
    }

    func resumeAfterTermination() {
        ownedTasks.resume()
        for index in recoverable.indices where recoverable[index].status == .transcribing {
            recoverable[index].status = .waiting
        }
        host?.voice.resumeAfterTermination()
        refreshRecoverable()
    }

    func retire() -> [Task<Void, Never>] {
        isRetired = true
        deleting.removeAll()
        return ownedTasks.cancelAll()
    }

    private func receive(_ text: String, recordingID: UUID, recording: DictationRecording<ExecutionTarget>?,
                         into draft: ComposerDraft) async throws {
        do { try await drafts.appendDictation(text, recordingID: recordingID, to: draft) }
        catch { throw DictationError.notAddedToDraft(error) }
        recoverable.removeAll { $0.id == recordingID }
        guard await drafts.flush(), let recording, let voice = host?.voice else { return }
        await voice.discard(recording)
    }

    private func apply(_ saved: [DictationRecording<ExecutionTarget>], voice: VoiceInputController) async {
        var received: [DictationRecording<ExecutionTarget>] = []
        var pending: [RecoverableDictation] = []
        do {
            for recording in saved where !deleting.contains(recording.id) {
                if try await drafts.hasSavedReceipt(for: recording.id) {
                    received.append(recording)
                } else {
                    let status = recoverable.first { $0.id == recording.id }?.status ?? .waiting
                    pending.append(RecoverableDictation(recording: recording, status: status))
                }
            }
            let maximumAge = TimeInterval(DictationRecordingStore<ExecutionTarget>.maximumAge.components.seconds)
            try await drafts.removeReceipts(receivedBefore: .now.addingTimeInterval(-maximumAge))
        } catch {
            logger.error("dictation receipts could not be read: \(error.localizedDescription, privacy: .public)")
            return
        }
        recoverable = pending
        for recording in received { await voice.discard(recording) }
    }

    private func recoveryFailed(_ id: UUID, error: any Error, feedback: (HapticEvent) -> Void) {
        if case .recordingMissing = error as? DictationRecordingError {
            recoverable.removeAll { $0.id == id }
            return
        }
        if let index = recoverable.firstIndex(where: { $0.id == id }) {
            recoverable[index].status = .failed(error.localizedDescription)
        }
        host?.dictationFailed(error.localizedDescription)
        feedback(.error)
    }
}
