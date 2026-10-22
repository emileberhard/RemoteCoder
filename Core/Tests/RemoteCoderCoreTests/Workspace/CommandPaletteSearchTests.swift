import Testing
@testable import RemoteCoderCore

struct CommandPaletteSearchTests {
    @Test func anEmptyQueryKeepsTheGivenOrderWithinTheLimit() {
        let candidates = ["One", "Two", "Three"].map { candidate($0) }
        #expect(CommandPaletteSearch.results(for: "  ", in: candidates, limit: 2) == ["One", "Two"])
    }

    @Test func prefixOutranksWordStartThenSubstringThenScatteredLetters() {
        let candidates = ["A rerun job", "Stop", "Ruin now", "Dry run", "Run tests"].map { candidate($0) }
        #expect(CommandPaletteSearch.results(for: "run", in: candidates, limit: 10)
            == ["Run tests", "Dry run", "A rerun job", "Ruin now"])
    }

    @Test func everyWordMustMatchTheTitleOrTheDetail() {
        let candidates = [
            candidate("Fix build", detail: "~/app · Mini", id: "mini build"),
            candidate("Fix build", detail: "~/app · MacBook", id: "book build"),
            candidate("Fix docs", detail: "~/site · Mini", id: "mini docs"),
        ]
        #expect(CommandPaletteSearch.results(for: "fix mini", in: candidates, limit: 10) == ["mini build", "mini docs"])
        #expect(CommandPaletteSearch.results(for: "build mini", in: candidates, limit: 10) == ["mini build"])
    }

    @Test func matchingIgnoresCaseAndDiacritics() {
        let candidates = [candidate("Café menu")]
        #expect(CommandPaletteSearch.results(for: "CAFE", in: candidates, limit: 10) == ["Café menu"])
        #expect(CommandPaletteSearch.results(for: "cafés", in: candidates, limit: 10).isEmpty)
    }

    @Test func scatteredLettersMatchOnlyInOrder() {
        let candidates = [candidate("RemoteCoder"), candidate("Credentials")]
        #expect(CommandPaletteSearch.results(for: "rmc", in: candidates, limit: 10) == ["RemoteCoder"])
    }

    @Test func theLimitBoundsEqualMatchesInTheGivenOrder() {
        let candidates = (1...10).map { candidate("Chat \($0)") }
        #expect(CommandPaletteSearch.results(for: "chat", in: candidates, limit: 3) == ["Chat 1", "Chat 2", "Chat 3"])
    }

    private func candidate(_ title: String, detail: String = "", id: String? = nil) -> CommandPaletteCandidate<String> {
        CommandPaletteCandidate(id: id ?? title, title: title, detail: detail)
    }
}
