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
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var resolvingNow: Task<Void, Never>?
    @ObservationIgnored private var readView: ChangesView?
    @ObservationIgnored private var isStale = false
    @ObservationIgnored private var loggedUnsupportedGateway = false
    @ObservationIgnored private let logger = AppLogger(category: "ChangeReview")
    private static let spacing = Duration.seconds(10)

    init(conversation: String, directory: String, client: GatewayClient, views: ConversationChangesViews,
         lastRead: ChangeSummaryRead?) {
        self.conversation = conversation
        self.directory = directory
        self.client = client
        self.views = views
        let stored = views.read()
        offersViews = stored != nil
        if let lastRead, lastRead.directory == directory, lastRead.content.view == stored ?? .standard {
            publish(lastRead)
        }
    }

    var lastRead: ChangeSummaryRead? {
        content.map { ChangeSummaryRead(directory: directory, content: $0, summary: summary) }
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
        resolvingNow?.cancel()
        resolvingNow = nil
        store(view)
    }

    func countFromNow() {
        guard offersViews else { return }
        resolvingNow?.cancel()
        resolvingNow = Task { [weak self, client, conversation] in
            do {
                guard let turnID = try await client.readNewestTurnID(threadID: conversation), !Task.isCancelled else { return }
                self?.store(.since(ChangesAnchor(turnID: turnID, boundary: .end)))
            } catch is CancellationError {
                return
            } catch {
                self?.logger.notice("Reading the newest turn failed: \(error.localizedDescription)")
            }
        }
    }

    private func store(_ view: ChangesView) {
        guard offersViews else { return }
        views.write(view)
        followView()
    }

    private func followView() {
        let stored = views.read()
        if (stored != nil) != offersViews { offersViews = stored != nil }
        guard let readView, readView != stored ?? .standard else { return }
        reading?.cancel()
        reading = nil
        refresh()
    }

    private func follow() {
        guard following == nil else { return }
        following = Task { [weak self] in
            for await _ in Observations({ @MainActor [weak self] in self?.views.read() }) {
                self?.followView()
            }
        }
    }

    func refresh() {
        follow()
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
        following?.cancel()
        following = nil
        resolvingNow?.cancel()
        resolvingNow = nil
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

    private func publish(_ read: ChangeSummaryRead?) {
        if read?.summary != summary { summary = read?.summary }
        if read?.content != content { content = read?.content }
        let isVisible = read?.content.isVisible ?? false
        if isVisible != self.isVisible { self.isVisible = isVisible }
        let start = read?.content.view.anchor.flatMap { $0.boundary == .end ? $0.turnID : nil }
        if start != startTurnID { startTurnID = start }
    }

    @concurrent private static func read(client: GatewayClient, conversation: String, directory: String,
                                         view: ChangesView) async throws -> ChangeSummaryRead {
        func result(_ content: ChangesPillContent, summary: PreparedChangeSummary? = nil) -> ChangeSummaryRead {
            ChangeSummaryRead(directory: directory, content: content, summary: summary)
        }
        switch view {
        case .git(let source):
            let summary = PreparedChangeSummary(try await client.readChangeSummary(
                threadID: conversation, directory: directory, source: source == .branch ? nil : source))
            return result(ChangesPillContent(view: view, count: .known(summary.totals)), summary: summary)
        case .lastTurn, .since:
            switch try await client.readTurnChanges(threadID: conversation, since: view.anchor) {
            case .ready(let changes):
                let since: TurnChanges.Since? = if case .since(let since) = changes.window { since } else { nil }
                return result(ChangesPillContent(view: view, since: since, count: .known(changes.totals)))
            case .noRecentEdits(true):
                let none = ChangeTotals(counted: [ChangeTotals.Lines?](), unlistedFiles: 0, isComplete: true)
                return result(ChangesPillContent(view: view, count: .known(none)))
            case .noRecentEdits(false):
                return result(ChangesPillContent(view: view, count: .unknown))
            case .anchorMissing:
                return result(ChangesPillContent(view: view, count: .startMissing))
            }
        }
    }
}

#if DEBUG
extension ChangeSummaryModel {
    func showPreview(_ summary: PreparedChangeSummary?, view: ChangesView = .standard) {
        offersViews = true
        publish(summary.map {
            ChangeSummaryRead(directory: directory, content: ChangesPillContent(view: view, count: .known($0.totals)), summary: $0)
        })
    }
}
#endif
