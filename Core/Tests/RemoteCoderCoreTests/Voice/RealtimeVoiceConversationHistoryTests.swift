import Foundation
import Testing

@testable import RemoteCoderCore

struct RealtimeVoiceConversationHistoryTests {
    @Test func historyBoundsOneVeryLargeMessage() {
        let items = RealtimeVoiceConversationHistory.initialItems(from: [
            RealtimeVoiceHistoryMessage(
                role: .assistant,
                text: String(repeating: "a", count: 40_000)
            ),
        ])

        #expect(items.count == 1)
        #expect(items[0].text.utf8.count <= 32_768)
        #expect(items[0].text.contains(RealtimeVoiceInitialItemsLimits.truncationMarker))
    }

    @Test func historyDropsBlankItemsWithoutLosingRoles() {
        let items = RealtimeVoiceConversationHistory.initialItems(from: [
            RealtimeVoiceHistoryMessage(role: .user, text: "  "),
            RealtimeVoiceHistoryMessage(role: .user, text: "Remember wombat"),
            RealtimeVoiceHistoryMessage(role: .assistant, text: "Understood"),
        ])

        #expect(items.map(\.role) == [.user, .assistant])
        #expect(items.map(\.text) == ["Remember wombat", "Understood"])
    }

    @Test func historyKeepsTheNewest128ItemsInOrderWithTheirRoles() {
        let messages = (0..<140).map { index in
            RealtimeVoiceHistoryMessage(role: index.isMultiple(of: 2) ? .user : .assistant, text: "message \(index)")
        }

        let items = RealtimeVoiceConversationHistory.initialItems(from: messages)

        #expect(items.count == 128)
        #expect(items.map(\.text) == (12..<140).map { "message \($0)" })
        #expect(items.first?.role == .user)
        #expect(items.last?.role == .assistant)
    }

    @Test func mergedHistoryOrdersVoiceAndChatByDateAndDropsAdjacentDuplicates() {
        let start = Date(timeIntervalSince1970: 1_000)
        let result = RealtimeVoiceConversationHistory.merged(
            chatMessages: [
                .init(role: .user, text: "Before voice", date: start),
                .init(role: .user, text: "After voice", date: start.addingTimeInterval(3)),
            ],
            voiceMessages: [
                .init(role: .assistant, text: "During voice", date: start.addingTimeInterval(1)),
                .init(role: .assistant, text: "During voice", date: start.addingTimeInterval(2)),
            ]
        )

        #expect(result.map(\.text) == ["Before voice", "During voice", "After voice"])
    }
}
