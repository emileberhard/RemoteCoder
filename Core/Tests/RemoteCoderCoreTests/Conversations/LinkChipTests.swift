import Foundation
import Testing
@testable import RemoteCoderCore

struct LinkChipTests {
    @Test(arguments: [
        ("https://github.com/example/project/pull/4636", LinkChip.web(iconHost: "github.com")),
        ("http://Docs.RS/tokio", .web(iconHost: "docs.rs")),
        ("https://localhost:3000/", .web(iconHost: nil)),
        ("http://192.168.1.20/admin", .web(iconHost: nil)),
        ("http://[::1]:8080/", .web(iconHost: nil)),
        ("https://workstation.tail1234.ts.net/", .web(iconHost: nil)),
        ("https://printer.local/", .web(iconHost: nil)),
        ("http://intranet/", .web(iconHost: nil)),
        ("file:///Users/developer/RemoteCoder/Chat/ChatTargetModel.swift#L1328", .file(symbol: "chevron.left.forwardslash.chevron.right")),
        ("file://localhost/tmp/shot.png", .file(symbol: "photo")),
        ("docs/provider-accounts.md", .file(symbol: "doc.text")),
        ("file://server/share/a.txt", .other),
        ("mailto:alex@example.com", .mail),
        ("tel:+46700000000", .phone),
        ("rc-visual:813d1e43ff7a418ea2866856d255678c3920e268aa4412ecc214e2d718cf8ea5", .other),
    ])
    func classifiesLinksLikeTheirOpener(link: String, expected: LinkChip) throws {
        #expect(LinkChip(url: try #require(URL(string: link))) == expected)
    }

    @Test func annotatesEveryLinkAndShortensOnlyBareURLs() throws {
        let text = MarkdownInlineRendering.parse(
            "See [#4636](https://github.com/example/project/pull/4636), https://github.com/openai/codex/blob/main/codex-rs/README.md, https://www.example.com/, http://localhost:3000/ and https://github.com/openai/codex/blob/main/codex-rs/lib.rs#L10-L20 too.")
            .annotatingLinkChips()
        let chips = text.runs[LinkChipAttribute.self].compactMap { style, range in
            style.map { (String(text[range].characters), $0) }
        }
        #expect(chips.map(\.0) == ["#4636", "https://github.com/openai/codex/blob/main/codex-rs/README.md", "https://www.example.com/",
            "http://localhost:3000/", "https://github.com/openai/codex/blob/main/codex-rs/lib.rs#L10-L20"])
        #expect(chips.map(\.1.shortLabel) == [nil, "github.com/…/codex-rs/README.md", "example.com", "localhost:3000", "github.com/…/codex-rs/lib.rs#L10-L20"])
        #expect(chips.map(\.1.chip) == [.web(iconHost: "github.com"), .web(iconHost: "github.com"), .web(iconHost: "www.example.com"),
            .web(iconHost: nil), .web(iconHost: "github.com")])
    }
}
