import Foundation
import Observation

@MainActor
@Observable
final class ChangeSummaryModel {
    let id = UUID()
    let conversation: String
    let directory: String
    private(set) var totals: ChangeTotals?
    private(set) var hasChanges = false
    private(set) var summary: PreparedChangeSummary?
    @ObservationIgnored private let client: GatewayClient
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private var isStale = false
    @ObservationIgnored private var loggedUnsupportedGateway = false
    @ObservationIgnored private let logger = AppLogger(category: "ChangeReview")
    private static let spacing = Duration.seconds(10)

    init(conversation: String, directory: String, client: GatewayClient) {
        self.conversation = conversation
        self.directory = directory
        self.client = client
    }

    func summarizes(conversation: String?, directory: String?) -> Bool {
        self.conversation == conversation && self.directory == directory
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
            do {
                let summary = try await Self.read(client: client, conversation: conversation, directory: directory)
                guard !Task.isCancelled else { return }
                publish(summary)
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

    private func publish(_ summary: PreparedChangeSummary?) {
        if summary != self.summary { self.summary = summary }
        let totals = summary?.totals
        if totals != self.totals { self.totals = totals }
        let hasChanges = (totals?.files ?? 0) > 0
        if hasChanges != self.hasChanges { self.hasChanges = hasChanges }
    }

    @concurrent private static func read(client: GatewayClient, conversation: String, directory: String) async throws -> PreparedChangeSummary {
        PreparedChangeSummary(try await client.readChangeSummary(threadID: conversation, directory: directory))
    }
}

#if DEBUG
extension ChangeSummaryModel {
    func showPreview(_ summary: PreparedChangeSummary?) {
        publish(summary)
    }
}
#endif
