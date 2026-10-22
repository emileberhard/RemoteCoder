import Foundation

struct RealtimeVoiceTranscriptEntry: Identifiable, Equatable, Sendable {
    typealias Role = RealtimeVoiceRole

    let id = UUID()
    let role: Role
    let text: String
}

struct RealtimeVoiceTranscriptState: Sendable {
    private(set) var entries: [RealtimeVoiceTranscriptEntry] = []
    private(set) var liveUserText = ""
    private(set) var liveAssistantText = ""
    private var assistantDeltasOnly = false
    private var providerConnectionID: UUID?

    mutating func beginProviderSession(connectionID: UUID) -> RealtimeVoiceTranscriptEntry? {
        guard providerConnectionID != connectionID else { return nil }
        providerConnectionID = connectionID
        assistantDeltasOnly = false
        return sealAssistant()
    }

    mutating func append(delta: String, role: RealtimeVoiceRole) -> Bool {
        guard !delta.isEmpty else { return false }
        switch role {
        case .user:
            liveUserText += delta
        case .assistant:
            liveAssistantText += delta
        }
        return true
    }

    mutating func complete(text: String, role: RealtimeVoiceRole) -> RealtimeVoiceTranscriptEntry? {
        switch role {
        case .user:
            liveUserText = ""
        case .assistant:
            let text = assistantDeltasOnly ? liveAssistantText : text
            liveAssistantText = ""
            return retain(text: text, role: role)
        }
        return retain(text: text, role: role)
    }

    mutating func interruptAssistant() -> RealtimeVoiceTranscriptEntry? {
        guard !liveAssistantText.isEmpty else { return nil }
        assistantDeltasOnly = true
        return sealAssistant()
    }

    mutating func reset() {
        entries.removeAll(keepingCapacity: true)
        liveUserText = ""
        liveAssistantText = ""
        assistantDeltasOnly = false
        providerConnectionID = nil
    }

    private mutating func sealAssistant() -> RealtimeVoiceTranscriptEntry? {
        let text = liveAssistantText
        liveAssistantText = ""
        return retain(text: text, role: .assistant)
    }

    private mutating func retain(text: String, role: RealtimeVoiceRole) -> RealtimeVoiceTranscriptEntry? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let entry = RealtimeVoiceTranscriptEntry(role: role, text: text)
        entries.append(entry)
        return entry
    }
}
