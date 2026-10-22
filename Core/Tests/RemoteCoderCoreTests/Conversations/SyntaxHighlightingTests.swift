import Testing
@testable import RemoteCoderCore

struct SyntaxHighlightingTests {
    @Test(arguments: [
        (#"let url = "https://example.com/a""#, []),
        (#"let url = "https://example.com/a" // actual comment"#, ["// actual comment"]),
        (#"let text = "// literal"; let count = 42 // count"#, ["// count"]),
        (#"let text = "Å 🐧 \"https://example.com\"" // Unicode"#, ["// Unicode"]),
        (#"// "https://example.com" remains a comment"#, [#"// "https://example.com" remains a comment"#]),
        ("// comment\rlet value = 42", ["// comment"]),
    ])
    func commentDelimitersInsideStringsStayLiteral(code: String, expected: [String]) {
        let comments = SyntaxHighlighting.tokens(in: code, language: "swift")
            .filter { $0.kind == .comment }.map { String(code[$0.range]) }
        #expect(comments == expected)
    }

    @Test func aLargeCommentBlockStaysWithinTheRenderingBudget() {
        let code = String(repeating: "// let value = 42\n", count: 20_000)
        let started = ContinuousClock.now
        let tokens = SyntaxHighlighting.tokens(in: code, language: "swift")
        let elapsed = started.duration(to: .now)
        #expect(tokens.count == 20_000)
        #expect(tokens.allSatisfy { $0.kind == .comment })
        #expect(elapsed < .seconds(1))
    }

    @Test func quotesInsideACommentCannotStartALaterString() {
        let code = """
        // Use " to open a literal
        // This is still documentation
        let endpoint = "https://example.com"
        """
        let tokens = SyntaxHighlighting.tokens(in: code, language: "swift")
        let comments = tokens.filter { $0.kind == .comment }.map { String(code[$0.range]) }
        let strings = tokens.filter { $0.kind == .string }.map { String(code[$0.range]) }
        #expect(comments == ["// Use \" to open a literal", "// This is still documentation"])
        #expect(strings == [#""https://example.com""#])
    }

    @Test func aCombiningMarkAfterTheOpeningQuoteStaysAString() {
        let literal = "\"\u{0301}literal\""
        let code = "let text = \(literal) // trailing comment"
        let tokens = SyntaxHighlighting.tokens(in: code, language: "swift")
        let strings = tokens.filter { $0.kind == .string }.map { String(code[$0.range]) }
        let comments = tokens.filter { $0.kind == .comment }.map { String(code[$0.range]) }
        #expect(strings == [literal])
        #expect(comments == ["// trailing comment"])
    }
}
