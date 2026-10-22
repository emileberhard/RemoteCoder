import Foundation

@MainActor
struct RecentConversationCache {
    struct Presentation {
        let messages: [ChatMessage]
        let items: [ChatStreamItem]
        let forkableMessageIDs: Set<UUID>
        weak var session: ConversationSession?

        init(_ snapshot: ConversationSnapshot, session: ConversationSession?) {
            messages = snapshot.messages
            items = snapshot.items
            forkableMessageIDs = snapshot.forkableMessageIDs
            self.session = session
        }
    }

    struct Settings {
        let model: ModelOption
        let reasoning: ReasoningSelection
        let fastModeState: FastModeState
    }

    private let capacity: Int
    private var presentations: [String: Presentation] = [:]
    private var settings: [String: Settings] = [:]
    private var agents: [String: ConversationAgentsModel] = [:]
    private var recency: [String] = []

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    func presentation(threadID: String) -> Presentation? { presentations[threadID] }

    func settings(threadID: String) -> Settings? { settings[threadID] }

    func agents(threadID: String) -> ConversationAgentsModel? { agents[threadID] }

    mutating func record(_ snapshot: ConversationSnapshot, session: ConversationSession?) {
        guard let threadID = snapshot.threadID, !snapshot.items.isEmpty else { return }
        presentations[threadID] = Presentation(snapshot, session: session)
        touch(threadID)
    }

    func admitsWarmed(_ threadID: String) -> Bool {
        recency.contains(threadID) || recency.count < capacity
    }

    mutating func recordWarmed(_ snapshot: ConversationSnapshot, session: ConversationSession?) {
        guard let threadID = snapshot.threadID, !snapshot.items.isEmpty else { return }
        presentations[threadID] = Presentation(snapshot, session: session)
        keepWarmed(threadID)
    }

    mutating func recordWarmed(_ value: ConversationAgentsModel) {
        agents[value.threadID] = value
        keepWarmed(value.threadID)
    }

    mutating func record(_ value: Settings, threadID: String) {
        settings[threadID] = value
        touch(threadID)
    }

    mutating func record(_ value: ConversationAgentsModel) {
        agents[value.threadID] = value
        touch(value.threadID)
    }

    mutating func removeAll(keeping threadIDs: Set<String>) {
        presentations = presentations.filter { threadIDs.contains($0.key) }
        settings = settings.filter { threadIDs.contains($0.key) }
        agents = agents.filter { threadIDs.contains($0.key) }
        recency.removeAll { presentations[$0] == nil && settings[$0] == nil && agents[$0] == nil }
    }

    private mutating func touch(_ threadID: String) {
        if recency.last != threadID {
            recency.removeAll { $0 == threadID }
            recency.append(threadID)
        }
        trim()
    }

    private mutating func keepWarmed(_ threadID: String) {
        if !recency.contains(threadID) { recency.insert(threadID, at: 0) }
        trim()
    }

    private mutating func trim() {
        while recency.count > capacity {
            let evicted = recency.removeFirst()
            presentations[evicted] = nil
            settings[evicted] = nil
            agents[evicted] = nil
        }
    }
}
