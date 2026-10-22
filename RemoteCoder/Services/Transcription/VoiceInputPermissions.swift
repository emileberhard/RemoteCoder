import Foundation
import AVFoundation
import Synchronization

enum VoiceInputPermissionError: LocalizedError {
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Microphone access is required for Voice Mode. Allow it in Settings, then try again."
        }
    }
}

/// Permission callbacks are delivered on an arbitrary queue. Keeping these bridges
/// explicitly nonisolated prevents Objective-C callbacks from inheriting MainActor.
enum VoiceInputPermissions {
    nonisolated static func requestMicrophoneAccess() async throws {
        let permission = AVAudioApplication.shared.recordPermission
        VoiceModeDiagnostics.log("microphone permission status=\(permission.rawValue)")
        switch permission {
        case .granted:
            return
        case .denied:
            throw VoiceInputPermissionError.microphoneDenied
        case .undetermined:
            let granted = try await awaitMicrophonePermission { completion in
                AVAudioApplication.requestRecordPermission(completionHandler: completion)
            }
            VoiceModeDiagnostics.log("microphone permission request completed granted=\(granted)")
            guard granted else {
                throw VoiceInputPermissionError.microphoneDenied
            }
        @unknown default:
            throw VoiceInputPermissionError.microphoneDenied
        }
    }

    nonisolated static func awaitMicrophonePermission(_ request: @Sendable (@escaping @Sendable (Bool) -> Void) -> Void) async throws -> Bool {
        let reply = MicrophonePermissionReply()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if reply.admit(continuation) {
                    request { reply.complete(.success($0)) }
                }
            }
        } onCancel: { reply.complete(.failure(CancellationError())) }
    }

}

nonisolated private final class MicrophonePermissionReply: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Bool, any Error>?
        var result: Result<Bool, any Error>?
    }
    private let state = Mutex(State())

    func admit(_ continuation: CheckedContinuation<Bool, any Error>) -> Bool {
        let result: Result<Bool, any Error>? = state.withLock { state in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result); return false }
        return true
    }

    func complete(_ result: Result<Bool, any Error>) {
        let continuation: CheckedContinuation<Bool, any Error>? = state.withLock { state in
            guard state.result == nil else { return nil }
            state.result = result
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}
