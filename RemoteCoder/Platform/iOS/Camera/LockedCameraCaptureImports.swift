import Foundation
import LockedCameraCapture

actor LockedCameraCaptureImports {
    static let shared = LockedCameraCaptureImports()
    private var requestID: UUID?
    private var worker: Task<Void, Error>?

    func receive(attach: @escaping @MainActor @Sendable ([URL]) throws -> Void) async throws {
        let id = UUID()
        requestID = id
        let previous = worker
        previous?.cancel()
        defer { if requestID == id { worker = nil } }
        _ = try? await previous?.value
        try Task.checkCancellation()
        guard requestID == id else { throw CancellationError() }
        let worker = Task { try await self.consume(attach: attach) }
        self.worker = worker
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    private func consume(attach: @MainActor @Sendable ([URL]) throws -> Void) async throws {
        let manager = LockedCameraCaptureManager.shared
        for await update in manager.sessionContentUpdates {
            try Task.checkCancellation()
            let urls: [URL]
            switch update {
            case .initial(let initial): urls = initial
            case .added(let added): urls = [added]
            case .removed: continue
            @unknown default: throw CameraCaptureError("The camera reported an unknown session update.")
            }
            let pending: [(url: URL, created: Date)] = try urls.map { url in
                guard let created = try url.resourceValues(forKeys: [.creationDateKey]).creationDate else {
                    throw CameraCaptureError("The captured photos' creation date is unavailable.")
                }
                return (url: url, created: created)
            }
            let sessions = pending.sorted { left, right in
                if left.created == right.created { return left.url.path < right.url.path }
                return left.created < right.created
            }
            for session in sessions {
                try Task.checkCancellation()
                if session.created >= Date.now.addingTimeInterval(-SharedItemsInbox.unclaimedLifetime),
                   let files = try CameraCaptureBatch.confirmedFiles(in: session.url) {
                    let moved = try move(files)
                    do { try await attach(moved.map { $0.destination }) }
                    catch {
                        try rollback(moved)
                        throw error
                    }
                    try CameraCaptureBatch.unconfirm(in: session.url)
                }
                try await manager.invalidateSessionContent(at: session.url)
            }
        }
    }

    private struct MovedFile {
        let original: URL
        let destination: URL
    }

    private func move(_ files: [URL]) throws -> [MovedFile] {
        var moved: [MovedFile] = []
        do {
            for file in files {
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw CameraCaptureError("The capture session contains an unexpected item.")
                }
                let directory = FileManager.default.temporaryDirectory.appending(
                    path: "CameraCaptures/\(UUID().uuidString)", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appending(path: file.lastPathComponent)
                do { try FileManager.default.moveItem(at: file, to: destination) }
                catch {
                    try FileManager.default.removeItem(at: directory)
                    throw error
                }
                moved.append(MovedFile(original: file, destination: destination))
            }
            return moved
        } catch {
            try rollback(moved)
            throw error
        }
    }

    private func rollback(_ moved: [MovedFile]) throws {
        for file in moved.reversed() {
            try FileManager.default.moveItem(at: file.destination, to: file.original)
            try FileManager.default.removeItem(at: file.destination.deletingLastPathComponent())
        }
    }
}
