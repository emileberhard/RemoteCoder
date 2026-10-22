import Foundation

struct NewChatSetup: Codable, Equatable, Sendable {
    let workingDirectory: String?
    let modelID: String?
    let reasoning: String
    let fastMode: Bool?

    init(workingDirectory: String?, modelID: String?, reasoning: ReasoningSelection, fastMode: Bool?) {
        self.workingDirectory = workingDirectory
        self.modelID = modelID
        self.reasoning = reasoning.id
        self.fastMode = fastMode
    }

    var reasoningSelection: ReasoningSelection? { ReasoningSelection.fromStorageValue(reasoning) }
}

struct UnsentDraftSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let setup: NewChatSetup?
    let modifiedAt: Date?

    static let titleLimit = 160

    static func title(text: String, attachmentCount: @autoclosure () -> Int) -> String? {
        let line = text.split(whereSeparator: \.isNewline)
            .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        if let line { return String(line.prefix(titleLimit)) }
        switch attachmentCount() {
        case 0: return nil
        case 1: return "1 attachment"
        case let count: return "\(count) attachments"
        }
    }

    static func newestFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        switch (lhs.modifiedAt, rhs.modifiedAt) {
        case let (left?, right?) where left != right: left > right
        case (.some, nil): true
        case (nil, .some): false
        default: lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

struct UnsentDraftAddress: Hashable, Codable, Sendable {
    let target: ExecutionTarget
    let draftID: UUID

    init(target: ExecutionTarget, draftID: UUID) {
        self.target = target
        self.draftID = draftID
    }

    private enum CodingKeys: CodingKey { case target, draftID }
    private struct RetiredTarget: Decodable { let accountID: UUID? }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let target = try values.decode(ExecutionTarget.self, forKey: .target)
        self.target = target
        let slot = try values.decode(UUID.self, forKey: .draftID)
        let account = try values.decode(RetiredTarget.self, forKey: .target).accountID
        draftID = account.map { AccountRetirementMigration.draftSlot(hostID: target.hostID, accountID: $0, slot: slot) } ?? slot
    }
}

struct UnsentDraftRow: Identifiable, Equatable, Sendable {
    let address: UnsentDraftAddress
    let title: String
    let workingDirectory: String
    let hostName: String
    let showsHostLabel: Bool
    let provider: AgentProvider?
    let modifiedAt: Date?
    let ageLabel: String?
    let isSelected: Bool

    var id: UnsentDraftAddress { address }

    static let collapsedLimit = 3

    struct TargetInput {
        let target: ExecutionTarget
        let hostName: String
        let remoteHomePath: String?
        let drafts: [UnsentDraftSummary]
    }

    static func rows(from targets: [TargetInput], selected: UnsentDraftAddress?, showsHostLabels: Bool,
                     query: String, condensedPaths: CondensedPathCache, now: Date) -> [UnsentDraftRow] {
        targets.flatMap { input in input.drafts.map { (input, $0) } }
            .sorted { UnsentDraftSummary.newestFirst($0.1, $1.1) }
            .map { input, draft in
                let address = UnsentDraftAddress(target: input.target, draftID: draft.id)
                return UnsentDraftRow(
                    address: address, title: draft.title,
                    workingDirectory: draft.setup?.workingDirectory.map {
                        condensedPaths.condensedPath($0, remoteHomePath: input.remoteHomePath)
                    } ?? "",
                    hostName: input.hostName, showsHostLabel: showsHostLabels,
                    provider: draft.setup?.modelID.map(AgentProvider.provider(forModelID:)),
                    modifiedAt: draft.modifiedAt,
                    ageLabel: draft.modifiedAt.map { ConversationSidebarDate.age(of: $0, now: now) },
                    isSelected: address == selected)
            }
            .filter { row in
                ConversationSidebarProjection.matches(title: row.title, workingDirectory: row.workingDirectory,
                                                      hostName: row.showsHostLabel ? row.hostName : nil, query: query)
            }
    }
}
