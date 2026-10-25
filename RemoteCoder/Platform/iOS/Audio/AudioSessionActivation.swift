import AVFoundation
import Foundation
import OSLog

@MainActor
enum AudioSessionActivation {
    private struct ActivationFailed: LocalizedError {
        var errorDescription: String? { "The audio session did not activate." }
    }

    private static let logger = AppLogger(category: "AudioSessionActivation")
    private static let retryDelays: [Duration] = [
        .milliseconds(250),
        .milliseconds(500),
        .seconds(1),
        .seconds(2),
    ]

    static func activate(_ session: AVAudioSession, context: String) async throws {
        var latestError: Error?

        for attempt in 0...retryDelays.count {
            try Task.checkCancellation()
            if attempt > 0 {
                try await Task.sleep(for: retryDelays[attempt - 1])
            }

            do {
                guard try await session.activate() else {
                    throw ActivationFailed()
                }
                if Task.isCancelled {
                    await deactivate(session, context: context)
                    throw CancellationError()
                }
                if attempt > 0 {
                    logger.notice(
                        "activated audio session for \(context) after \(attempt + 1) attempts"
                    )
                }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                latestError = error
                let nsError = error as NSError
                if attempt < retryDelays.count {
                    logger.notice(
                        "audio-session activation for \(context) was temporarily unavailable (domain: \(nsError.domain), code: \(nsError.code)); retrying"
                    )
                }
            }
        }

        let error = latestError ?? ActivationFailed()
        logger.error("audio-session activation for \(context) failed: \(error.localizedDescription)")
        throw error
    }

    @discardableResult
    static func deactivate(_ session: AVAudioSession, context: String) async -> Bool {
        do {
            guard try await session.deactivate(options: [.notifyOthersOnDeactivation]) else {
                logger.error("audio-session deactivation for \(context) did not complete")
                return false
            }
            logger.notice("deactivated audio session for \(context)")
            return true
        } catch {
            logger.error(
                "audio-session deactivation for \(context) failed: \(error.localizedDescription)"
            )
            return false
        }
    }
}
