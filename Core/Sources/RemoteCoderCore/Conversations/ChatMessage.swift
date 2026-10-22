import CryptoKit
import Foundation

struct ChatMessage: Identifiable, Sendable, Equatable, Codable {
    enum Role: String, Sendable, Codable { case user, codex }
    enum Delivery: Sendable, Equatable { case sending, pendingSteer, steered, queueing, queued, notSent, unconfirmed }
    let id: UUID
    let role: Role
    var text: String
    var attachments: [MessageAttachment]
    var inlineContent: InlineMessageContent?
    var date: Date
    /// Sent into a turn already in progress rather than starting one.
    ///
    /// Live sends know this directly. Reconstructed history derives it: a steer is
    /// recorded inside the turn it interrupted, so any user message after a turn's
    /// first one was steered.
    var wasSteered: Bool
    var delivery: Delivery?
    var isStreaming: Bool
    var canonicalTurnID: String?
    var canonicalItemID: String?
    /// Set when this user message is a reply envelope to a model question; the
    /// bubble then shows each question with its answer instead of the raw text.
    var questionReplies: [QuestionReply]?

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        fileAttachments: [UploadedFile] = [],
        attachments: [MessageAttachment] = [],
        inlineContent: InlineMessageContent? = nil,
        date: Date = Date(),
        wasSteered: Bool = false,
        canonicalTurnID: String? = nil,
        canonicalItemID: String? = nil,
        questionReplies: [QuestionReply]? = nil,
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments + fileAttachments.map { MessageAttachment(id: Self.deterministicID(for: "file:\($0.path)"), content: .file($0)) }
        self.inlineContent = inlineContent
        self.date = date
        self.wasSteered = wasSteered
        self.isStreaming = isStreaming
        self.canonicalTurnID = canonicalTurnID
        self.canonicalItemID = canonicalItemID
        self.questionReplies = questionReplies
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, bodyText, attachments, attachmentOrder, inlineContent, date, wasSteered
        case canonicalTurnID, canonicalItemID, questionReplies, isStreaming
    }

    private enum LegacyCodingKeys: String, CodingKey { case imageAttachments, fileAttachments }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        role = try values.decode(Role.self, forKey: .role)
        text = try values.decodeIfPresent(String.self, forKey: .bodyText) ?? values.decode(String.self, forKey: .text)
        attachments = try values.decodeIfPresent([MessageAttachment].self, forKey: .attachments) ?? []
        inlineContent = try values.decodeIfPresent(InlineMessageContent.self, forKey: .inlineContent)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        attachments += (try legacy.decodeIfPresent([CodexImageAttachment].self, forKey: .imageAttachments) ?? [])
            .map { MessageAttachment(id: $0.id, content: .imageData($0)) }
        if !values.contains(.attachments) {
            attachments += (try legacy.decodeIfPresent([UploadedFile].self, forKey: .fileAttachments) ?? [])
                .map { MessageAttachment(id: Self.deterministicID(for: "file:\($0.path)"), content: .file($0)) }
        }
        if let order = try values.decodeIfPresent([UUID].self, forKey: .attachmentOrder) {
            let positions = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
            attachments.sort { positions[$0.id, default: .max] < positions[$1.id, default: .max] }
        }
        date = try values.decode(Date.self, forKey: .date)
        wasSteered = try values.decode(Bool.self, forKey: .wasSteered)
        canonicalTurnID = try values.decodeIfPresent(String.self, forKey: .canonicalTurnID)
        canonicalItemID = try values.decodeIfPresent(String.self, forKey: .canonicalItemID)
        questionReplies = try values.decodeIfPresent([QuestionReply].self, forKey: .questionReplies)
        isStreaming = try values.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(role, forKey: .role)
        let fallback = attachments.compactMap { attachment -> String? in
            switch attachment.content {
            case .text(let text): inlineContent == nil ? text : nil
            case .image, .canonicalImage, .unavailableImage: Self.imageAttachmentText
            case .localImage(let path): "\(Self.imageAttachmentText): \(path)"
            case .fileReference(let path): "\(Self.fileAttachmentText): \(path)"
            case .imageData, .file: nil
            }
        }
        let readable = inlineContent?.document.expandedText ?? text
        try values.encode(([readable] + fallback).filter { !$0.isEmpty }.joined(separator: "\n\n"), forKey: .text)
        if !fallback.isEmpty || inlineContent != nil { try values.encode(text, forKey: .bodyText) }
        try values.encodeIfPresent(inlineContent, forKey: .inlineContent)
        try values.encode(attachments.filter {
            switch $0.content {
            case .imageData: false
            case .text, .image, .canonicalImage, .unavailableImage, .localImage, .fileReference, .file: true
            }
        }, forKey: .attachments)
        try values.encode(attachments.map(\.id), forKey: .attachmentOrder)
        var legacy = encoder.container(keyedBy: LegacyCodingKeys.self)
        try legacy.encode(attachments.compactMap {
            if case .imageData(let image) = $0.content { image } else { nil }
        }, forKey: .imageAttachments)
        try legacy.encode(attachments.compactMap {
            if case .file(let file) = $0.content { file } else { nil }
        }, forKey: .fileAttachments)
        try values.encode(date, forKey: .date)
        try values.encode(wasSteered, forKey: .wasSteered)
        try values.encodeIfPresent(canonicalTurnID, forKey: .canonicalTurnID)
        try values.encodeIfPresent(canonicalItemID, forKey: .canonicalItemID)
        try values.encodeIfPresent(questionReplies, forKey: .questionReplies)
        try values.encode(isStreaming, forKey: .isStreaming)
    }

    static let imageAttachmentText = "Image attachment"
    static let fileAttachmentText = "File attachment"

    mutating func useCanonicalImages(_ inputs: [CodexAppServerV2.UserInput]) {
        guard attachments.contains(where: {
            switch $0.content { case .imageData, .unavailableImage: true; default: false }
        }) else { return }
        let images = inputs.filter {
            switch $0 { case .image, .localImage: true; default: false }
        }.map { input -> Data? in
            guard case .image(.inline(let url)) = input, url.hasPrefix("data:image/"),
                  let delimiter = url.range(of: ";base64,") else { return nil }
            return Data(base64Encoded: String(url[delimiter.upperBound...]))
        }
        var index = 0
        attachments = attachments.map { attachment in
            switch attachment.content {
            case .imageData, .canonicalImage, .unavailableImage:
                defer { index += 1 }
                guard images.indices.contains(index), let canonical = images[index] else { return attachment }
                if case .imageData(let local) = attachment.content, canonical != local.data { return attachment }
                return MessageAttachment(id: attachment.id, content: .canonicalImage(index))
            default: return attachment
            }
        }
    }

    static func deterministicID(for key: String) -> UUID {
        let digest = SHA256.hash(data: Data(key.utf8))
        var bytes = Array(digest.prefix(16))
        // Stamp RFC 4122 variant/version bits so the UUID formatting stays standard.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
