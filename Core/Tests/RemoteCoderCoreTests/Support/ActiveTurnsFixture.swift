import Foundation

@testable import RemoteCoderCore

enum ActiveTurnsFixture {
    static let codexThread = "01a087fa-1348-7a93-8881-4b406d7bbc8b"
    static let claudeThread = "claude_01a087fa-1348-7a93-8881-4b406d7bbc8b"
    static let observed = Date(timeIntervalSince1970: 1_788_995_200)
    static let confirmed = observed.addingTimeInterval(TurnRegistry.confirmationWindow)

    static func turn(
        thread: String,
        id: String,
        startedAt: Double? = 1_788_995_000,
        cwd: String? = "/Users/developer/RemoteCoder"
    ) -> CodexGatewayDaemon.ActiveTurn {
        CodexGatewayDaemon.ActiveTurn(
            threadId: thread,
            turnId: id,
            startedAtUnixSeconds: startedAt,
            startedAtSequence: nil,
            promptPreview: "hey! u know the ai inspo meeting",
            cwd: cwd
        )
    }

    static func snapshot(
        revision: UInt64 = 1,
        active: [CodexGatewayDaemon.ActiveTurn] = [],
        codexCovered: Bool = true,
        agentOwners: [String: String] = [:]
    ) -> CodexGatewayDaemon.ActiveTurnsResponse {
        CodexGatewayDaemon.ActiveTurnsResponse(
            epoch: "epoch",
            revision: revision,
            activeTurns: active,
            coverage: .init(codex: codexCovered, claude: true),
            externalActivity: .init(sessions: [], claudeAvailable: true, codexAvailable: true),
            agentOwners: agentOwners
        )
    }

    static func job(thread: String, turn: String) -> ActiveJob {
        ActiveJob(id: GatewayNotificationRouting.jobID(threadID: thread, turnID: turn), threadID: thread)
    }
}
