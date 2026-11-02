import Foundation
import Observation

@MainActor
@Observable
final class ChangeSummaryModel {
    let conversation: String
    let directory: String
    private(set) var totals: ChangeTotals?
    @ObservationIgnored private let client: GatewayClient
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private var isStale = false
    @ObservationIgnored private let logger = AppLogger(category: "ChangeReview")
    private static let spacing = Duration.seconds(2)

    init(conversation: String, directory: String, client: GatewayClient) {
        self.conversation = conversation
        self.directory = directory
        self.client = client
    }

    func summarizes(conversation: String?, directory: String?) -> Bool {
        self.conversation == conversation && self.directory == directory
    }

    var hasChanges: Bool {
        (totals?.files ?? 0) > 0
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

    func stop() -> Task<Void, Never>? {
        defer { reading = nil }
        reading?.cancel()
        return reading
    }

    private func readWhileStale() async {
        repeat {
            isStale = false
            do {
                let totals = try await Self.read(client: client, conversation: conversation, directory: directory)
                guard !Task.isCancelled else { return }
                if totals != self.totals { self.totals = totals }
            } catch {
                guard !Task.isCancelled else { return }
                logger.notice("Summarizing changes failed: \(error.localizedDescription)")
            }
            guard isStale else { break }
            guard (try? await Task.sleep(for: Self.spacing)) != nil else { return }
        } while true
        reading = nil
    }

    @concurrent private static func read(client: GatewayClient, conversation: String, directory: String) async throws -> ChangeTotals? {
        let root = try? await client.readCheckouts(threadID: conversation, directory: directory).defaultRoot
        switch try await client.readChanges(directory: root ?? directory, source: ChangeReviewModel.defaultSource) {
        case .ready(let snapshot): return ChangeTotals(snapshot)
        case .unavailable: return nil
        }
    }
}
