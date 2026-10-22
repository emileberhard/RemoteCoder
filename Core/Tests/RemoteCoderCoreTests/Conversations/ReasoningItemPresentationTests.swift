import Testing

@testable import RemoteCoderCore

struct ReasoningItemPresentationTests {
    private func thinking(summary: [String], content: [String] = []) -> JobTimelineEvent? {
        ConversationItemPresentation.event(jobID: "job", sequence: 0, timestamp: nil,
                                           item: .reasoning(id: "r", summary: summary, content: content))
    }

    @Test func codexHeadingsShowAsCleanLinesWithNothingHidden() throws {
        let event = try #require(thinking(summary: ["**Checking swap usage**", "**Designing broker isolation**"]))
        #expect(event.subtitle == "Checking swap usage\nDesigning broker isolation")
        #expect(event.details.isEmpty)
    }

    @Test func aStreamingHeadingShowsWithoutItsOpeningMarker() throws {
        let event = try #require(thinking(summary: ["**Checking sw"]))
        #expect(event.subtitle == "Checking sw")
    }

    @Test func proseShowsItsFirstLineAndKeepsTheRestForDetails() throws {
        let event = try #require(thinking(summary: ["I should check the logs.\n\nThen compare both hosts."]))
        #expect(event.subtitle == "I should check the logs.")
        #expect(event.details.map(\.value) == ["Then compare both hosts."])
    }

    @Test func aHeadingWithABodyLeadsAndTheBodyFollows() throws {
        let event = try #require(thinking(summary: ["**Planning**\n\nRead the parser first."]))
        #expect(event.subtitle == "Planning")
        #expect(event.details.map(\.value) == ["Read the parser first."])
    }

    @Test func rawContentStandsInWhenThereIsNoSummary() throws {
        let event = try #require(thinking(summary: [" "], content: ["Raw reasoning."]))
        #expect(event.subtitle == "Raw reasoning.")
        #expect(event.details.isEmpty)
    }

    @Test func emptyReasoningRendersNoRow() {
        #expect(thinking(summary: ["", "  "], content: []) == nil)
        #expect(thinking(summary: ["**  **"]) == nil)
    }
}
