import Foundation
import UniformTypeIdentifiers

enum LinkChip: Hashable, Sendable {
    case web(iconHost: String?)
    case file(symbol: String)
    case mail
    case phone
    case other

    init(url: URL) {
        switch url.scheme?.lowercased() {
        case "http", "https":
            self = .web(iconHost: url.host(percentEncoded: true).flatMap(Self.publicIconHost))
        case "mailto":
            self = .mail
        case "tel":
            self = .phone
        default:
            if let link = try? HostFileLink(url: url) {
                self = .file(symbol: Self.symbol(forFileNamed: link.path))
            } else {
                self = .other
            }
        }
    }

    static func symbol(forFileNamed name: String) -> String {
        guard let type = UTType(filenameExtension: URL(filePath: name).pathExtension) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .audiovisualContent) { return "film" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .sourceCode) { return "chevron.left.forwardslash.chevron.right" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }

    private static let privateSuffixes = ["localhost", "local", "internal", "lan", "home.arpa", "ts.net", "test", "invalid", "example"]

    private static func publicIconHost(_ host: String) -> String? {
        let host = host.lowercased()
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count > 1, labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.allSatisfy { $0 == UInt8(ascii: "-") || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
        }), !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              !privateSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return host
    }
}

struct LinkChipStyle: Hashable, Sendable {
    let chip: LinkChip
    let shortLabel: String?
}

enum LinkChipAttribute: AttributedStringKey {
    typealias Value = LinkChipStyle
    static let name = "RemoteCoder.linkChip"
}

extension AttributedString {
    func annotatingLinkChips() -> AttributedString {
        var text = self
        for (url, range) in runs[\.link].reversed() {
            guard let url else { continue }
            let label = String(self[range].characters)
            text[range][LinkChipAttribute.self] = LinkChipStyle(chip: LinkChip(url: url),
                shortLabel: label == url.absoluteString ? Self.shortLabel(for: url) : nil)
        }
        return text
    }

    private static func shortLabel(for url: URL) -> String? {
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        var site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if let port = url.port { site += ":\(port)" }
        let components = url.path(percentEncoded: false).split(separator: "/")
        let label = components.count > 2
            ? "\(site)/…/\(components.suffix(2).joined(separator: "/"))"
            : ([site] + components.map(String.init)).joined(separator: "/")
        guard let fragment = url.fragment(percentEncoded: false), !fragment.isEmpty else { return label }
        return "\(label)#\(fragment)"
    }
}
