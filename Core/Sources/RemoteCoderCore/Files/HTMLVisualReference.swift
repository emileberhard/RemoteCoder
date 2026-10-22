import CryptoKit
import Foundation

struct HTMLVisualReference: Hashable, Sendable {
    let url: URL
    let digest: String

    init?(url: URL) {
        let value = url.absoluteString
        guard value.hasPrefix("rc-visual:"), value.utf8.count == 74 else { return nil }
        let digest = String(value.dropFirst(10))
        guard digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        self.url = url
        self.digest = digest
    }

    func verify(_ data: Data) throws -> String {
        guard data.count <= Self.maximumBytes else { throw HTMLVisualError.tooLarge }
        guard let html = String(data: data, encoding: .utf8) else { throw HTMLVisualError.invalidUTF8 }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == digest else { throw HTMLVisualError.digestMismatch }
        return html
    }

    static let maximumBytes = 2 << 20
}

enum HTMLVisualPreparationOutcome: Equatable, Sendable {
    case settled(stored: Int, unpreparable: Int)
    case incomplete(missing: Int)
    case interrupted
    case unsupported
}

struct HTMLVisualPreparationContext: Hashable, Sendable {
    let width: Int
    let theme: HTMLVisualTheme
}

enum HTMLVisualError: Error, LocalizedError, Sendable, Equatable {
    case tooLarge
    case invalidUTF8
    case digestMismatch
    case invalidCache

    var errorDescription: String? {
        switch self {
        case .tooLarge: "This visual exceeds the 2 MiB limit."
        case .invalidUTF8: "This visual is not valid UTF-8 HTML."
        case .digestMismatch: "This visual's content does not match its reference."
        case .invalidCache: "The saved visual could not be read."
        }
    }
}
