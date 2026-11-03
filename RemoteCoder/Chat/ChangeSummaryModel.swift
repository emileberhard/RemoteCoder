import Foundation
import Observation

struct ConversationChangesViews {
    let read: @MainActor () -> ChangesView?
    let write: @MainActor (ChangesView) -> Void
    let startPoints: @MainActor () -> ChangesStartPoints
}

@MainActor
@Observable
final class ChangeSummaryModel {
    let id = UUID()
    let conversation: String
    let directory: String
    private(set) var content: ChangesPillContent?
    private(set) var summary: PreparedChangeSummary?
    private(set) var offersViews = false
    private(set) var isVisible = false
    private(set) var startTurnID: String?
    @ObservationIgnored private let client: GatewayClient
    @ObservationIgnored private let views: ConversationChangesViews
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private var readView: ChangesView?
    @ObservationIgnored private var isStale = false
    @ObservationIgnored private var loggedUnsupportedGateway = false
    @ObservationIgnored private let logger = AppLogger(category: "ChangeReview")
    private static let spacing = Duration.seconds(10)

    init(conversation: String, directory: String, client: GatewayClient, views: ConversationChangesViews) {
        self.conversation = conversation
        self.directory = directory
        self.client = client
        self.views = views
    }

    func summarizes(conversation: String?, directory: String?) -> Bool {
        self.conversation == conversation && self.directory == directory
    }

    var view: ChangesView {
        views.read() ?? .standard
    }

    func startPoints() -> ChangesStartPoints {
        views.startPoints()
    }

    func select(_ view: ChangesView) {
        guard offersViews else { return }
        views.write(view)
        followView()
    }

    func countFromNow() {
        guard let now = startPoints().now else { return }
        select(.since(now))
    }

    func followView() {
        let stored = views.read()
        if (stored != nil) != offersViews { offersViews = stored != nil }
        guard let readView, readView != stored ?? .standard else { return }
        stop()
        refresh()
    }

    func refresh() {
        guard reading == nil else {
            isStale = true
            return
        }
        reading = Task { [weak self] in
            await self?.readWhileStale()
        }
    }

    @discardableResult
    func stop() -> Task<Void, Never>? {
        defer { reading = nil }
        reading?.cancel()
        return reading
    }

    private func readWhileStale() async {
        repeat {
            isStale = false
            let stored = views.read()
            if (stored != nil) != offersViews { offersViews = stored != nil }
            let view = stored ?? .standard
            readView = view
            do {
                let read = try await Self.read(client: client, conversation: conversation, directory: directory, view: view)
                guard !Task.isCancelled else { return }
                publish(read)
            } catch GatewayClient.ClientError.serverError(_, let code) where code == -32601 {
                guard !Task.isCancelled else { return }
                publish(nil)
                if !loggedUnsupportedGateway {
                    loggedUnsupportedGateway = true
                    logger.notice("Changes summary is unavailable until the gateway updates")
                }
            } catch {
                guard !Task.isCancelled else { return }
                logger.notice("Summarizing changes failed: \(error.localizedDescription)")
            }
            guard (try? await Task.sleep(for: Self.spacing)) != nil else { return }
        } while isStale
        reading = nil
    }

    private func publish(_ read: Read?) {
        if read?.summary != summary { summary = read?.summary }
        if read?.content != content { content = read?.content }
        let isVisible = read?.content.isVisible ?? false
        if isVisible != self.isVisible { self.isVisible = isVisible }
        let start = read?.content.view.anchor.flatMap { $0.boundary == .end ? $0.turnID : nil }
        if start != startTurnID { startTurnID = start }
    }

    private struct Read: Sendable {
        let content: ChangesPillContent
        let summary: PreparedChangeSummary?
    }

    @concurrent private static func read(client: GatewayClient, conversation: String, directory: String,
                                         view: ChangesView) async throws -> Read {
        switch view {
        case .git(let source):
            let summary = PreparedChangeSummary(try await client.readChangeSummary(
                threadID: conversation, directory: directory, source: source == .branch ? nil : source))
            return Read(content: ChangesPillContent(view: view, totals: summary.totals), summary: summary)
        case .lastTurn, .since:
            switch try await client.readTurnChanges(threadID: conversation, since: view.anchor) {
            case .ready(let changes):
                let since: TurnChanges.Since? = if case .since(let since) = changes.window { since } else { nil }
                return Read(content: ChangesPillContent(view: view, since: since, totals: changes.totals), summary: nil)
            case .noRecentEdits(let complete):
                let none = ChangeTotals(counted: [ChangeTotals.Lines?](), unlistedFiles: 0, isComplete: complete)
                return Read(content: ChangesPillContent(view: view, totals: none), summary: nil)
            case .anchorMissing:
                return Read(content: ChangesPillContent(view: view, totals: nil), summary: nil)
            }
        }
    }
}

#if DEBUG
extension ChangeSummaryModel {
    func showPreview(_ summary: PreparedChangeSummary?, view: ChangesView = .standard) {
        offersViews = true
        publish(summary.map { Read(content: ChangesPillContent(view: view, totals: $0.totals), summary: $0) })
    }
}
#endif
