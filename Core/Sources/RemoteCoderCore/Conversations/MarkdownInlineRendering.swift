import Foundation

struct MarkdownImage: Sendable, Equatable {
    let url: URL
    let alt: String
}

enum MarkdownInlineRendering {
    static func parse(_ text: String) -> AttributedString {
        let span = PerfBuild.span("markdown.inline")
        defer { span.end() }
        return (try? AttributedString(markdown: text, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(text)
    }

    static func standaloneVisual(_ text: String) -> MarkdownImage? {
        guard text.contains("rc-visual:"), let images = standaloneImages(parse(text)),
              images.count == 1, let image = images.first, image.url.scheme == "rc-visual" else { return nil }
        return image
    }

    private static let emptyImageAlt = "\u{FFFC}"

    static func imageAlt(_ characters: String, url: URL) -> String {
        let alt = characters.replacingOccurrences(of: emptyImageAlt, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return alt.isEmpty ? url.lastPathComponent : alt
    }

    static func standaloneImages(_ content: AttributedString) -> [MarkdownImage]? {
        var images: [MarkdownImage] = []
        var current: (url: URL, alt: String)?
        func finish() {
            guard let image = current else { return }
            images.append(MarkdownImage(url: image.url, alt: imageAlt(image.alt, url: image.url)))
            current = nil
        }
        for run in content.runs {
            let characters = String(content[run.range].characters)
            guard let url = run.imageURL, run.link == nil else {
                guard characters.allSatisfy(\.isWhitespace) else { return nil }
                finish()
                continue
            }
            if current?.url == url { current?.alt += characters } else {
                finish()
                current = (url, characters)
            }
        }
        finish()
        return images.isEmpty ? nil : images
    }
}

extension HTMLVisualReference {
    static func references(inMarkdown text: String) -> [HTMLVisualReference] {
        var seen = Set<String>()
        return text.matches(of: /\]\((rc-visual:[0-9a-f]{64})\)/).compactMap { match in
            URL(string: String(match.output.1)).flatMap(HTMLVisualReference.init(url:))
        }.filter { seen.insert($0.digest).inserted }
    }

    static func standaloneReferences(inMarkdown text: String) -> [HTMLVisualReference] {
        var fence: MarkdownFence?
        var references: [HTMLVisualReference] = []
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if let open = fence {
                if open.closes(line) { fence = nil }
                continue
            }
            if let opening = MarkdownFence(line) {
                fence = opening
                continue
            }
            if let image = MarkdownInlineRendering.standaloneVisual(String(line)), let reference = Self(url: image.url) {
                references.append(reference)
            }
        }
        return references
    }
}
