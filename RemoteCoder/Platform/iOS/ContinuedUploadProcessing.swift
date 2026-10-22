import BackgroundTasks
import Foundation
import os

@MainActor
final class ContinuedUploadProcessing: UploadContinuation {
    private static let identifierPrefix: String = {
        guard let bundleID = Bundle.main.bundleIdentifier else { preconditionFailure("Missing bundle identifier") }
        return bundleID + ".upload."
    }()
    private let logger = Logger(subsystem: "RemoteCoder", category: "Uploads")

    private struct Owner {
        weak var uploads: FileAttachmentImports?
    }

    private enum State {
        case idle
        case requested
        case running(BGContinuedProcessingTask)
    }

    private var owners: [ObjectIdentifier: Owner] = [:]
    private var state = State.idle
    private var shownSubtitle = ""

    func begin(for uploads: FileAttachmentImports) {
        track(uploads)
        guard case .idle = state, total.files > 0 else { return report() }
        let identifier = Self.identifierPrefix + UUID().uuidString
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self else { return task.setTaskCompleted(success: false) }
                self.start(task)
            }
        }
        guard registered else {
            logger.error("Upload continuation \(identifier, privacy: .public) is not a permitted task identifier")
            return
        }
        state = .requested
        let title = title(for: total)
        Task { [weak self] in
            do {
                try await Self.submit(identifier: identifier, title: title)
            } catch {
                self?.logger.error("Upload continuation was not submitted: \(error.localizedDescription, privacy: .public)")
                guard let self, case .requested = self.state else { return }
                self.state = .idle
            }
        }
    }

    @concurrent
    private static func submit(identifier: String, title: String) async throws {
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: "Preparing")
        try await BGTaskScheduler.shared.submitTaskRequest(request)
    }

    func progressChanged(in uploads: FileAttachmentImports) {
        track(uploads)
        report()
    }

    private func track(_ uploads: FileAttachmentImports) {
        owners = owners.filter { $0.value.uploads != nil }
        owners[ObjectIdentifier(uploads)] = Owner(uploads: uploads)
    }

    private var total: FileAttachmentImports.Transfer {
        owners.values.compactMap(\.uploads).map(\.transfer).reduce(into: FileAttachmentImports.Transfer()) { total, transfer in
            total.files += transfer.files
            total.completedBytes += transfer.completedBytes
            total.totalBytes += transfer.totalBytes
            total.hasFailures = total.hasFailures || transfer.hasFailures
        }
    }

    private func start(_ task: BGTask) {
        guard let task = task as? BGContinuedProcessingTask else {
            state = .idle
            return task.setTaskCompleted(success: false)
        }
        let identity = ObjectIdentifier(task)
        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in self?.expire(identity) }
        }
        state = .running(task)
        shownSubtitle = ""
        report()
    }

    private func report() {
        guard case .running(let task) = state else { return }
        let total = total
        guard total.files > 0 else {
            state = .idle
            task.setTaskCompleted(success: !total.hasFailures)
            return
        }
        task.progress.totalUnitCount = max(total.totalBytes, 1)
        task.progress.completedUnitCount = min(total.completedBytes, total.totalBytes)
        let subtitle = total.totalBytes > 0
            ? "\(Self.bytes(total.completedBytes)) of \(Self.bytes(total.totalBytes))"
            : "Preparing"
        guard subtitle != shownSubtitle else { return }
        shownSubtitle = subtitle
        task.updateTitle(title(for: total), subtitle: subtitle)
    }

    private func expire(_ identity: ObjectIdentifier) {
        guard case .running(let task) = state, ObjectIdentifier(task) == identity else { return }
        state = .idle
        logger.notice("Upload continuation ended by the system or the person; uploads pause until the app is active")
        for uploads in owners.values.compactMap(\.uploads) { uploads.pauseUntilActive() }
        task.setTaskCompleted(success: false)
    }

    private func title(for total: FileAttachmentImports.Transfer) -> String {
        total.files == 1 ? "Uploading a file" : "Uploading \(total.files) files"
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
