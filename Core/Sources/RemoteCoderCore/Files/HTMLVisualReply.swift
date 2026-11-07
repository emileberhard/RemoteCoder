import Foundation

struct HTMLVisualReplyKey: Hashable, Sendable, Codable {
    let turnID: String
    let digest: String

    init?(turnID: String, digest: String) {
        guard Self.isValidTurnID(turnID), HTMLVisualReference.isDigest(digest) else { return nil }
        self.turnID = turnID
        self.digest = digest
    }

    static let maximumTurnIDBytes = 128

    static func isValidTurnID(_ turnID: String) -> Bool {
        !turnID.isEmpty && turnID.utf8.count <= maximumTurnIDBytes
            && turnID.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F && $0 != "\"" && $0 != "<" && $0 != ">" }
    }
}

struct HTMLVisualReply: Sendable, Equatable, Codable {
    let key: HTMLVisualReplyKey
    let text: String

    static let maximumBytes = 16 * 1_024

    init?(key: HTMLVisualReplyKey, text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= Self.maximumBytes else { return nil }
        self.key = key
        self.text = text
    }
}
