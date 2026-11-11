import AVFoundation
import Foundation
import Observation
import SpeakerRecognition
import SpeechKit

@MainActor
@Observable
final class DictationVoiceProfiles {
    enum Status: String {
        case learning = "Learning"
        case learned = "Learned"
        case unavailable = "Unavailable"
    }

    private var isTrusted = false
    private var routeUnavailable = false
    var status: Status { routeUnavailable ? .unavailable : isTrusted ? .learned : .learning }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: VoiceProfileStore
    @ObservationIgnored private var appliedForget = Date.distantPast
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private let logger = AppLogger(category: "DictationVoices")

    init(defaults: UserDefaults, directory: URL) {
        self.defaults = defaults
        store = VoiceProfileStore(accountDirectory: directory)
    }

    deinit {
        refreshTask?.cancel()
        historyTask?.cancel()
        store.retire()
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await applyForget()
                let profile = try await store.profile()
                try Task.checkCancellation()
                isTrusted = profile.isTrusted
            } catch is CancellationError {
            } catch { failed(error) }
        }
    }

    func makeCheck() async throws -> VoiceCheck {
        try await applyForget()
        let profile = try await store.profile()
        return try VoiceCheck(profile: profile, store: store, startedAt: .now) { [weak self] stage, failure in
            Task { @MainActor in self?.failed(failure, stage: stage) }
        }
    }

    func checked(_ result: VoiceCheckResult) {
        if result.labelledReplyTime != nil { routeUnavailable = false }
        refresh()
    }

    func forget() async {
        let date = max(Date.now, forgottenAt)
        defaults.set(date.timeIntervalSince1970, forKey: TranscriptionSettings.voiceForgottenAtKey)
        do {
            historyTask?.cancel()
            try await applyForget()
            isTrusted = false
        } catch { failed(error) }
    }

    func cancelHistoryLearning() { historyTask?.cancel() }

    func learnFromHistory(in library: SharedDictationLibrary?) {
        guard historyTask == nil, let library, library.isEnabled else { return }
        historyTask = Task { [weak self] in
            guard let self else { return }
            defer { historyTask = nil }
            do {
                try await applyForget()
                guard let window = try await store.beginHistory() else { return }
                let originals = try await library.localVoiceHistory()
                let history = try await VoiceHistory.learn(from: originals.recordings, in: window, decode: Self.decode)
                try Task.checkCancellation()
                try await library.validateAccount(originals.account)
                _ = try await store.learnHistory(history.candidates, in: window)
                refresh()
            } catch is CancellationError {
            } catch { failed(error, stage: .learning) }
        }
    }

    func failed(_ error: any Error, stage: VoiceFilterStage = .filter) {
        if stage == .filter, Self.routeRefused(error) { routeUnavailable = true }
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
        case SpeechKitError.relayRejected(let kind):
            ["unavailable", "unauthorized", "authenticationUnavailable", "notPermitted", "operationNotAllowed", "credentialsUnavailable", "upstreamRejected"].contains(kind)
        case SpeechKitError.httpFailure(let status, _): [401, 403, 404].contains(status)
        case is GatewaySpeechFailure: true
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
