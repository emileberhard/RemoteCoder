import Foundation
import Testing
import WebKit
@testable import RemoteCoder

struct MermaidMarkdownTests {
    private func parse(_ source: String, streaming: Bool = false) -> [RenderedMarkdownBlock.Content] {
        var highlighting = SyntaxHighlightCache()
        return MarkdownRendering.parse(source, previous: nil, isStreaming: streaming,
                                       highlighting: &highlighting).blocks.map(\.content)
    }

    @Test(arguments: ["```mermaid", "```Mermaid", "~~~mermaid", "  ```mermaid", "````mermaid", "```mermaid title=Example"])
    func recognizesMermaidFences(_ opening: String) throws {
        let closing = opening.contains("~~~~") ? "~~~~" : opening.contains("~~~") ? "~~~" : opening.contains("````") ? "````" : "```"
        let blocks = parse("\(opening)\nflowchart LR\nA-->B\n\(closing)\nAfter", streaming: true)
        guard case .mermaid(let source, let complete) = try #require(blocks.first) else {
            Issue.record("Expected a Mermaid illustration"); return
        }
        #expect(source == "flowchart LR\nA-->B")
        #expect(complete)
        #expect(blocks.count == 2)
    }

    @Test func incompleteFenceWaitsButTerminalSourceGetsAnAttempt() throws {
        let input = "```mermaid\nflowchart LR\nA-->B"
        #expect(parse(input, streaming: true) == [.mermaid(source: "flowchart LR\nA-->B", isComplete: false)])
        #expect(parse(input) == [.mermaid(source: "flowchart LR\nA-->B", isComplete: true)])
    }

    @Test(arguments: ["swift", "mermaidish", "mermaid-js", "", "text"])
    func otherCodeStaysCode(_ language: String) throws {
        guard case .codeBlock(_, let source, _) = try #require(parse("```\(language)\nflowchart LR\nA-->B\n```").first) else {
            Issue.record("Only explicitly labelled Mermaid blocks may render diagrams"); return
        }
        #expect(source == "flowchart LR\nA-->B")
    }

    @Test func mismatchedAndShortFencesCannotCloseCode() throws {
        guard case .codeBlock(_, let source, _) = try #require(parse("````text\n```mermaid\nA-->B\n```\n~~~\n````tail\n````").first) else {
            Issue.record("Expected one code fence"); return
        }
        #expect(source == "```mermaid\nA-->B\n```\n~~~\n````tail")
    }

    @Test func sourceQuotesUnicodeAndIndentationSurvive() {
        let source = "flowchart LR\nA[\"Åsa's iPhone 🐧\"] --> B[\"\\path & text\"]"
        #expect(parse("  ~~~mermaid\n  \(source.replacingOccurrences(of: "\n", with: "\n  "))\n  ~~~") == [.mermaid(source: source, isComplete: true)])
    }

    @Test func proseAndMultipleDiagramsStayInOrder() {
        let blocks = parse("Before\n\n```mermaid\nflowchart TD\nA-->B\n```\nBetween\n~~~mermaid\nsequenceDiagram\nA->>B: Hello\n~~~\nAfter")
        #expect(blocks.count == 5)
        #expect(blocks[1] == .mermaid(source: "flowchart TD\nA-->B", isComplete: true))
        #expect(blocks[3] == .mermaid(source: "sequenceDiagram\nA->>B: Hello", isComplete: true))
    }
}

/// Exercises the shipped JS and headless WebKit, not a mock or a JS parser alone.
@Suite(.serialized)
@MainActor
struct MermaidWebKitTests {
    @Test(arguments: [
        "flowchart LR\nA[Alpha] --> B[Beta]",
        "sequenceDiagram\nparticipant A as Alpha\nA->>B: Hello",
        "stateDiagram-v2\n[*] --> Alpha\nAlpha --> Beta",
        "classDiagram\nclass Alpha\nAlpha --> Beta",
        "erDiagram\nAlpha ||--o{ Beta : contains",
        "gantt\ntitle Alpha\ndateFormat YYYY-MM-DD\nsection Work\nBeta :2026-01-01, 2d",
        "pie title Alpha\n\"Beta\" : 42\n\"Gamma\" : 58",
        "mindmap\n  root((Alpha))\n    Beta\n    Gamma",
        "timeline\ntitle Alpha\n2026 : Beta",
        "gitGraph\ncommit id: \"Alpha\"\nbranch beta\ncheckout beta\ncommit",
        "requirementDiagram\nrequirement Alpha {\nid: 1\ntext: Ready\nrisk: low\nverifymethod: test\n}",
        "block-beta\ncolumns 2\nAlpha Beta\nAlpha-->Beta",
        "xychart-beta\ntitle \"Alpha\"\nx-axis [Jan, Feb]\ny-axis 0 --> 10\nbar [4, 7]",
        "architecture-beta\nservice a(server)[Alpha]\nservice b(database)[Beta]\na:R --> L:b"
    ])
    func rendersDiagramFamiliesOffline(_ source: String) async throws {
        let renderer = MermaidRenderer()
        let result = try await renderer.diagram(for: MermaidRequest(source: source, isDark: false, highContrast: false))
        #expect(result.svg.contains("Alpha"))
        #expect(result.size.width > 0 && result.size.height > 0)
        #expect(result.preview.count > 100)
        #expect(Array(result.preview.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
        #expect(!result.svg.contains("<script"))
    }

    @Test func accessibilityAndAppearanceArePreserved() async throws {
        let renderer = MermaidRenderer()
        let source = "flowchart TD\naccTitle: Audio path\naccDescr: Audio travels from the phone through the gateway.\nA[Phone] --> B[Gateway]"
        let light = try await renderer.diagram(for: MermaidRequest(source: source, isDark: false, highContrast: false))
        let dark = try await renderer.diagram(for: MermaidRequest(source: source, isDark: true, highContrast: true))
        #expect(light.title == "Audio path")
        #expect(light.summary.contains("gateway"))
        #expect(light.preview != dark.preview)
        #expect(light.background != dark.background)
    }

    @Test func invalidInputFailsInsteadOfReturningMermaidErrorArtwork() async {
        let renderer = MermaidRenderer()
        await #expect(throws: MermaidFailure.self) {
            try await renderer.diagram(for: MermaidRequest(source: "not a diagram at all", isDark: false, highContrast: false))
        }
    }

    @Test func sourceCannotWeakenSecurityOrAddNavigableLinks() async throws {
        let renderer = MermaidRenderer()
        let source = """
        %%{init: {'securityLevel':'loose','htmlLabels':true}}%%
        flowchart LR
        A[Safe] --> B[Text]
        click A "https://example.invalid/leak" "Untrusted link"
        """
        let result = try await renderer.diagram(for: MermaidRequest(source: source, isDark: false, highContrast: false))
        #expect(!result.svg.contains("https://example.invalid"))
        #expect(!result.svg.contains("<a "))
        #expect(!result.svg.contains("onclick="))
        let configuration = MermaidWebContent.configuration()
        #expect(!configuration.loadsSubresources)
        #expect(!configuration.websiteDataStore.isPersistent)
    }

    @Test func malformedQuotesAreDataAndCannotExecuteScript() async {
        let renderer = MermaidRenderer()
        let source = "flowchart LR\nA[\"</script><script>throw new Error('executed')</script>\"] --> B[Text]"
        do {
            let result = try await renderer.diagram(for: MermaidRequest(source: source, isDark: false, highContrast: false))
            #expect(!result.svg.contains("<script"))
        } catch {
            #expect(error is MermaidFailure)
            #expect(!error.localizedDescription.contains("Error: executed"))
        }
    }
}
