import Foundation

enum CodexGatewayDaemon {}

extension CodexGatewayDaemon {
    enum ActivityState: String, Decodable, Sendable {
        case working, waiting, idle, unknown
    }

    struct ActiveTurnsResponse: Decodable, Sendable {
        enum OwnersCoverage: String, Decodable, Sendable {
            case complete, unavailable
        }

        struct Coverage: Decodable, Equatable, Sendable {
            let codex: Bool
            let claude: Bool

            func covers(_ provider: AgentProvider) -> Bool {
                switch provider {
                case .codex: codex
                case .claude: claude
                }
            }
        }

        let epoch: String
        let revision: UInt64
        let activeTurns: [ActiveTurn]
        let coverage: Coverage
        let externalActivity: ExternalActivity
        var agentOwners: [String: String]
        var agentOwnersCoverage: OwnersCoverage? = nil

        func canConfirmInactivity(for threadID: String) -> Bool {
            coverage.covers(AgentProvider.provider(forThreadID: threadID))
        }
    }

    struct ExternalActivity: Decodable, Sendable {
        let sessions: [SessionActivity]
        let claudeAvailable: Bool
        let codexAvailable: Bool

        struct SessionActivity: Decodable, Sendable {
            let threadId: String
            let state: ActivityState
            let owner: SessionOwner?
            var waitingSince: Int64? = nil
        }

        enum SessionOwner: String, Decodable, Sendable {
            case gateway, client
        }
    }

    struct ActiveTurn: Decodable, Sendable {
        let threadId: String
        let turnId: String
        let startedAtUnixSeconds: Double?
        let startedAtSequence: UInt64?
        let promptPreview: String
        let cwd: String?
    }

    struct ReplayNotificationsResponse: Decodable, Sendable {
        let generatedAtUnixSeconds: Double
        let epoch: String
        let throughSequence: UInt64
        let hasMore: Bool
        let evictedBefore: Bool
        let skipped: [ReplayProgress.Page.Skipped]
        let notifications: [ReplayedNotification]

        var page: ReplayProgress.Page {
            .init(epoch: epoch, throughSequence: throughSequence, hasMore: hasMore,
                evictedBefore: evictedBefore, skipped: skipped)
        }
    }

    struct ReplayedNotification: Decodable, Sendable {
        let sequence: UInt64
        let timestampUnixSeconds: Double
        let message: JSONValue
    }
}
