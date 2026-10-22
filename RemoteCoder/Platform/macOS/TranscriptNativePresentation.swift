#if os(macOS)
import SwiftUI

extension EnvironmentValues {
    @Entry var transcriptSurfaceRetention: TranscriptSurfaceRetention?
    @Entry var transcriptSurfaceActivity: TranscriptSurfaceActivity?
}

@MainActor
final class TranscriptSurfaceActivity {
    enum State { case mounted, detached, retired }
    var state = State.mounted

    func recordBody() {
        if state == .detached { PerfBuild.count("native.detachedBody") }
    }
}

@MainActor
final class TranscriptNativePresentation {
    let endpoint = TranscriptNativeEndpoint()
    let halt = TranscriptScrollHalt()
    let visibility = TranscriptVisibility()
    let codeExport = TranscriptCodeExportPresenter()
    let actions = TranscriptNativeActions()
    let activity = TranscriptSurfaceActivity()
    let rowProjection = TranscriptRowProjection()
    let follow: TranscriptFollow

    init(readingPosition: TranscriptReadingPosition) {
        follow = TranscriptFollow(isFollowingLatest: readingPosition.isFollowingLatest)
    }

    func restoreFollowing(_ following: Bool) {
        if following { follow.followLatest() } else { follow.readHistory() }
    }
}

@MainActor
final class TranscriptNativeActions {
    private var onOpenAttachment: ((MessageAttachment) -> Void)?
    private var onLoadHistory: ((HistoryEdge) -> Void)?
    private var onToggleTimeline: ((String, String) -> Void)?
    private var onFork: ((ChatMessage) -> Void)?
    private var queued: QueuedMessageActions?
    private var onRefreshCompaction: (() -> Void)?

    func bind(openAttachment: @escaping (MessageAttachment) -> Void, loadHistory: @escaping (HistoryEdge) -> Void,
              toggleTimeline: @escaping (String, String) -> Void, onFork: @escaping (ChatMessage) -> Void,
              queuedActions: QueuedMessageActions, refreshCompaction: (() -> Void)?) {
        onOpenAttachment = openAttachment
        onLoadHistory = loadHistory
        onToggleTimeline = toggleTimeline
        self.onFork = onFork
        queued = queuedActions
        onRefreshCompaction = refreshCompaction
    }

    func clear() {
        onOpenAttachment = nil
        onLoadHistory = nil
        onToggleTimeline = nil
        onFork = nil
        queued = nil
        onRefreshCompaction = nil
    }

    func openAttachment(_ attachment: MessageAttachment) { onOpenAttachment?(attachment) }
    func loadHistory(_ edge: HistoryEdge) { onLoadHistory?(edge) }
    func toggleTimeline(_ id: String, rowID: String) { onToggleTimeline?(id, rowID) }
    func fork(_ message: ChatMessage) { onFork?(message) }
    func refreshCompaction() { onRefreshCompaction?() }

    var queuedActions: QueuedMessageActions {
        QueuedMessageActions(sendNow: queued?.sendNow == nil ? nil : { [weak self] in self?.queued?.sendNow?($0) },
                             remove: { [weak self] in self?.queued?.remove($0) })
    }
}
#endif
