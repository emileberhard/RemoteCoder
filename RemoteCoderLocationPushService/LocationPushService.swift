import CoreLocation
import Foundation
import OSLog

final class LocationPushService: NSObject, CLLocationPushServiceExtension, @unchecked Sendable {
    private let logger = Logger(subsystem: "RemoteCoder", category: "LocationPushService")
    private let lock = NSLock()
    private var activeTask: Task<Void, Never>?
    private var completion: CompletionOnce?
    private var activeGeneration: UUID?

    func didReceiveLocationPushPayload(
        _ payload: [String: Any],
        completion: @escaping () -> Void
    ) {
        let completionOnce = CompletionOnce(completion)
        let command: LiveNavigationCommand
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            command = try JSONDecoder().decode(LiveNavigationCommand.self, from: data)
            try command.validate()
        } catch {
            logger.error("Rejected location push: \(error.localizedDescription, privacy: .public)")
            completionOnce.call()
            return
        }

        let generation = UUID()
        let claim = lock.withLock {
            let previous = (activeTask, self.completion)
            activeTask = nil
            self.completion = completionOnce
            activeGeneration = generation
            let storage: Result<Void, Error>
            do {
                try LiveNavigationCommandStore.save(command: command)
                storage = .success(())
            } catch {
                activeGeneration = nil
                self.completion = nil
                storage = .failure(error)
            }
            return (previous.0, previous.1, storage)
        }
        claim.0?.cancel()
        claim.1?.call()
        if case .failure(let error) = claim.2 {
            logger.error("Could not store location push: \(error.localizedDescription, privacy: .public)")
            completionOnce.call()
            return
        }
        LiveNavigationConstants.postCommandChangedNotification()

        let task = Task { [weak self] in
            guard let self else {
                completionOnce.call()
                return
            }
            await handle(command, generation: generation, completion: completionOnce)
        }
        lock.withLock {
            if activeGeneration == generation {
                activeTask = task
            } else {
                task.cancel()
            }
        }
    }

    func serviceExtensionWillTerminate() {
        let current = lock.withLock {
            let current = (activeTask, completion)
            activeTask = nil
            completion = nil
            activeGeneration = nil
            return current
        }
        current.0?.cancel()
        current.1?.call()
    }

    private func handle(
        _ command: LiveNavigationCommand,
        generation: UUID,
        completion: CompletionOnce
    ) async {
        let serviceSession = CLServiceSession(
            authorization: .always,
            fullAccuracyPurposeKey: LiveNavigationConstants.fullAccuracyPurposeKey
        )
        _ = serviceSession

        do {
            guard let location = try await firstLocation(configuration: command.profile.liveUpdateConfiguration) else {
                throw LiveNavigationError.invalidCommand("Core Location returned no location before the extension deadline")
            }
            let event = LiveNavigationEvent(
                schemaVersion: 1,
                sessionId: command.sessionId,
                sequence: 1,
                kind: .bootstrap,
                sentAtUnixSeconds: Date().timeIntervalSince1970,
                rawLocation: LiveNavigationLocation(location),
                roadSnappedLocation: nil,
                guidance: nil,
                message: "Location push extension acquired the bootstrap fix."
            )
            let response = try await LiveNavigationUploader.upload(event, using: command)
            guard isActive(generation: generation) else {
                finish(generation: generation, completion: completion)
                return
            }
            guard try LiveNavigationCommandStore.saveProgress(
                command: command,
                acceptedSequence: response.acceptedSequence
            ) else {
                finish(generation: generation, completion: completion)
                return
            }
            if response.command?.type == "stop" {
                try LiveNavigationCommandStore.clear(sessionID: command.sessionId)
            }
            logger.notice("Uploaded bootstrap fix for navigation session \(command.sessionId, privacy: .public)")
        } catch {
            logger.error("Location push handling failed: \(error.localizedDescription, privacy: .public)")
            if Task.isCancelled == false, isActive(generation: generation) {
                await uploadFailure(error, command: command)
            }
        }

        finish(generation: generation, completion: completion)
    }

    private func isActive(generation: UUID) -> Bool {
        lock.withLock { activeGeneration == generation }
    }

    private func finish(generation: UUID, completion: CompletionOnce) {
        completion.call()
        lock.withLock {
            if activeGeneration == generation {
                activeTask = nil
                self.completion = nil
                activeGeneration = nil
            }
        }
    }

    private func firstLocation(
        configuration: CLLocationUpdate.LiveConfiguration
    ) async throws -> CLLocation? {
        for try await update in CLLocationUpdate.liveUpdates(configuration) {
            try Task.checkCancellation()
            if let location = update.location {
                return location
            }
        }
        return nil
    }

    private func uploadFailure(_ error: Error, command: LiveNavigationCommand) async {
        let event = LiveNavigationEvent(
            schemaVersion: 1,
            sessionId: command.sessionId,
            sequence: 1,
            kind: .error,
            sentAtUnixSeconds: Date().timeIntervalSince1970,
            rawLocation: nil,
            roadSnappedLocation: nil,
            guidance: nil,
            message: error.localizedDescription
        )
        _ = try? await LiveNavigationUploader.upload(event, using: command)
    }
}

private final class CompletionOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (() -> Void)?

    init(_ completion: @escaping () -> Void) {
        self.completion = completion
    }

    func call() {
        let action = lock.withLock {
            defer { completion = nil }
            return completion
        }
        action?()
    }
}
