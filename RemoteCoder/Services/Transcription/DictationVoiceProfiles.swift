import AVFoundation
import Foundation
import Observation
import SpeakerRecognition
import SpeechKit

struct DictationVoiceHistory: Sendable {
    let recordings: [VoiceHistoryRecording]
    let validate: @MainActor @Sendable () async throws -> Void
}

@MainActor
@Observable
final class DictationVoiceProfiles {
    enum Status: String {
        case learning = "Learning"
        case learned = "Learned"
        case unavailable = "Unavailable"
    }

    private var active = false
    private(set) var hasProfile = false
    @ObservationIgnored private let profileURL: URL
    private var isTrusted = false
    private var unavailableHosts: Set<UUID> = []
    func status(for hostID: UUID?) -> Status {
        if let hostID, unavailableHosts.contains(hostID) { return .unavailable }
        return isTrusted ? .learned : .learning
    }
    @ObservationIgnored private let history: @MainActor () async throws -> DictationVoiceHistory?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: VoiceProfileStore
    @ObservationIgnored private var appliedForget = Date.distantPast
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private let logger = AppLogger(category: "DictationVoices")

    init(defaults: UserDefaults, directory: URL, history: @escaping @MainActor () async throws -> DictationVoiceHistory?) {
        self.history = history
        profileURL = directory.appending(path: "VoiceProfile.json")
        self.defaults = defaults
        store = VoiceProfileStore(accountDirectory: directory)
    }

    deinit {
        refreshTask?.cancel()
        historyTask?.cancel()
        store.retire()
    }

    func refresh(active: Bool) {
        self.active = active
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await applyForget()
                let exists = await Self.profileExists(at: profileURL)
                try Task.checkCancellation()
                hasProfile = exists
                guard active else { return }
                let profile = try await store.profile()
                try Task.checkCancellation()
                isTrusted = profile.isTrusted
            } catch is CancellationError {
            } catch { failed(error, stage: .filter) }
        }
    }

    func makeCheck(for hostID: UUID) async throws -> VoiceCheck {
        try await applyForget()
        let profile = try await store.profile()
        return try VoiceCheck(profile: profile, store: store, startedAt: .now) { [weak self] stage, failure in
            Task { @MainActor in self?.failed(failure, stage: stage, hostID: hostID) }
        }
    }

    func checked(_ result: VoiceCheckResult, hostID: UUID) {
        if result.outcome.path != .failed, result.labelledReplyTime != nil { unavailableHosts.remove(hostID) }
        refresh(active: active)
    }

    func forget() async {
        refreshTask?.cancel()
        let date = max(Date.now, forgottenAt)
        defaults.set(date.timeIntervalSince1970, forKey: TranscriptionSettings.voiceForgottenAtKey)
        do {
            historyTask?.cancel()
            try await applyForget()
            isTrusted = false
            hasProfile = false
        } catch { failed(error, stage: .filter) }
        refresh(active: active)
    }

    func cancelHistoryLearning() { historyTask?.cancel() }

    func learnFromHistory() {
        guard historyTask == nil else { return }
        historyTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { historyTask = nil }
            do {
                try await applyForget()
                guard let window = try await store.beginHistory(), let originals = try await history() else { return }
                let history = try await VoiceHistory.learn(from: originals.recordings, in: window, decode: Self.decode)
                try Task.checkCancellation()
                try await originals.validate()
                _ = try await store.learnHistory(history.candidates, in: window)
                refresh(active: active)
            } catch is CancellationError {
            } catch { failed(error, stage: .learning) }
        }
    }

    func failed(_ error: any Error, stage: VoiceFilterStage, hostID: UUID? = nil) {
        if stage == .filter, let hostID, Self.routeRefused(error) { unavailableHosts.insert(hostID) }
        logger.error("Optional voice check failed stage=\(stage.rawValue) error=\(Self.failureDescription(error))")
    }

    private static func failureDescription(_ error: any Error) -> String {
        switch error {
        case SpeechKitError.relayRejected(let kind): "relayRejected(\(kind))"
        case SpeechKitError.httpFailure(let status, _): "HTTP \(status)"
        case let error as URLError: "URL error \(error.code.rawValue)"
        default: String(reflecting: type(of: error))
        }
    }

    private static func routeRefused(_ error: any Error) -> Bool {
        switch error {
        case SpeechKitError.httpFailure(let status, _): [401, 403, 404].contains(status)
        case let error as GatewaySpeechFailure: [401, 403, 404].contains(error.status)
        default: false
        }
    }

    private var forgottenAt: Date {
        let seconds = defaults.double(forKey: TranscriptionSettings.voiceForgottenAtKey)
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : .distantPast
    }

    private func applyForget() async throws {
        let date = forgottenAt
        guard date > appliedForget else { return }
        try await store.forget(learnedBefore: date)
        appliedForget = max(appliedForget, date)
        isTrusted = false
        hasProfile = false
    }

    @concurrent private static func profileExists(at url: URL) async -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @concurrent static func decode(_ url: URL) async throws -> Data {
        let file = try AVAudioFile(forReading: url)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw CocoaError(.coderInvalidValue) }
        var pcm = Data()
        while true {
            try Task.checkCancellation()
            var error: NSError?
            var readFailure: (any Error)?
            let status = converter.convert(to: output, error: &error) { _, state in
                do {
                    let remaining = file.length - file.framePosition
                    guard remaining > 0 else { state.pointee = .endOfStream; return nil }
                    try file.read(into: input, frameCount: AVAudioFrameCount(min(remaining, AVAudioFramePosition(input.frameCapacity))))
                    state.pointee = input.frameLength > 0 ? .haveData : .endOfStream
                    return input.frameLength > 0 ? input : nil
                } catch {
                    readFailure = error
                    state.pointee = .endOfStream
                    return nil
                }
            }
            if let readFailure { throw readFailure }
            if let error { throw error }
            if let samples = output.int16ChannelData {
                pcm.append(Data(bytes: samples[0], count: Int(output.frameLength) * 2))
            }
            guard pcm.count <= VoiceCheck.maximumSamples * 2 else { throw CocoaError(.fileReadTooLarge) }
            if status == .endOfStream { return pcm }
            if status == .error { throw CocoaError(.fileReadCorruptFile) }
        }
    }
}
