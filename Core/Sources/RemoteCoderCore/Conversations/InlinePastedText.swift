import Foundation

struct ComposerDocumentContent: Sendable, Codable, Equatable {
    enum Run: Sendable, Codable, Equatable {
        case text(String)
        case paste(PastedTextPromptBlock.Entry)
    }

    let runs: [Run]

    init(runs: [Run]) {
        var normalized: [Run] = []
        var text: [String] = []
        func appendText() {
            guard !text.isEmpty else { return }
            normalized.append(.text(text.joined()))
            text.removeAll(keepingCapacity: true)
        }
        for run in runs {
            switch run {
            case .text(let value):
                if !value.isEmpty { text.append(value) }
            case .paste(let entry):
                if entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if !entry.text.isEmpty { text.append(entry.text) }
                } else {
                    appendText()
                    normalized.append(run)
                }
            }
        }
        appendText()
        self.runs = normalized
    }

    private enum CodingKeys: String, CodingKey { case runs }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let runs = try values.decode([Run].self, forKey: .runs)
        var ids: Set<UUID> = []
        for run in runs {
            if case .paste(let entry) = run {
                guard ids.insert(entry.id).inserted, !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw DecodingError.dataCorruptedError(forKey: .runs, in: values, debugDescription: "Inline pastes require unique IDs and nonempty text")
                }
            }
        }
        self.init(runs: runs)
    }

    func avoidingPasteIDs(_ existing: Set<UUID>) -> Self {
        var ids = existing
        return .init(runs: runs.map { run in
            guard case .paste(let entry) = run else { return run }
            let id = ids.insert(entry.id).inserted ? entry.id : UUID()
            ids.insert(id)
            return .paste(.init(id: id, text: entry.text))
        })
    }

    var expandedText: String {
        runs.map { run in
            switch run {
            case .text(let text): text
            case .paste(let entry): entry.text
            }
        }.joined()
    }

    var pasted: [PastedTextPromptBlock.Entry] {
        runs.compactMap { if case .paste(let entry) = $0 { entry } else { nil } }
    }

    var summary: String {
        runs.map { run in
            switch run {
            case .text(let text): text
            case .paste: "[Pasted text]"
            }
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var prompt: String {
        runs.map { run in
            switch run {
            case .text(let text): InlinePastedText.encodeText(text)
            case .paste(let entry):
                "\(InlinePastedText.start)\(entry.id.uuidString)\" bytes=\"\(entry.text.utf8.count)\">\n\(entry.text)\(InlinePastedText.end)"
            }
        }.joined()
    }
}

enum InlinePastedText {
    static let start = "<remotecoder_pasted_text_v2 id=\""
    static let end = "\n</remotecoder_pasted_text_v2>"
    static let literalStart = "<remotecoder_literal_text_v2 bytes=\""
    static let literalEnd = "\n</remotecoder_literal_text_v2>"

    fileprivate static func encodeText(_ text: String) -> String {
        guard ["<remotecoder_pasted_text_v1>", "<remotecoder_pasted_text_v2", "<remotecoder_literal_text_v2",
               AttachedFilesPromptBlock.render([])].contains(where: text.contains) else { return text }
        return "\(literalStart)\(text.utf8.count)\">\n\(text)\(literalEnd)"
    }

    static func parse(_ text: String) -> ComposerDocumentContent? {
        var cursor = text.startIndex
        var search = cursor
        var runs: [ComposerDocumentContent.Run] = []
        var ids: Set<UUID> = []
        var recognized = false
        let byteCount = text.utf8.count
        while let marker = PromptMarkerSearch.range(of: "<remotecoder_", in: text, range: search..<text.endIndex) {
            search = marker.upperBound
            let tail = text[marker.lowerBound...]
            let run: ComposerDocumentContent.Run
            let next: String.Index
            if tail.hasPrefix(start) {
                let header = text.index(marker.lowerBound, offsetBy: start.count)
                guard let (entry, end) = parseEntry(in: text, after: header, byteCount: byteCount) else { continue }
                guard ids.insert(entry.id).inserted else { return nil }
                run = .paste(entry)
                next = end
            } else if tail.hasPrefix(literalStart) {
                let header = text.index(marker.lowerBound, offsetBy: literalStart.count)
                guard let (literal, end) = parseLiteral(in: text, after: header, byteCount: byteCount) else { continue }
                run = .text(literal)
                next = end
            } else { continue }
            if cursor < marker.lowerBound { runs.append(.text(String(text[cursor..<marker.lowerBound]))) }
            runs.append(run)
            recognized = true
            cursor = next
            search = next
        }
        guard recognized else { return nil }
        if cursor < text.endIndex { runs.append(.text(String(text[cursor...]))) }
        return ComposerDocumentContent(runs: runs)
    }

    private static func parseLiteral(in text: String, after start: String.Index, byteCount: Int) -> (String, String.Index)? {
        let header = text[start...].prefix(14)
        guard let headerEnd = header.range(of: "\">\n") else { return nil }
        let lengthText = String(header[..<headerEnd.lowerBound])
        return parsePayload(in: text, start: headerEnd.upperBound, lengthText: lengthText, end: literalEnd, byteCount: byteCount)
    }

    private static func parseEntry(in text: String, after start: String.Index, byteCount: Int) -> (PastedTextPromptBlock.Entry, String.Index)? {
        let header = text[start...].prefix(100)
        guard let headerEnd = header.range(of: ">\n") else { return nil }
        let fields = header[..<headerEnd.lowerBound].components(separatedBy: "\"")
        guard fields.count == 4, fields[1] == " bytes=", fields[3].isEmpty,
              let id = UUID(uuidString: fields[0]),
              let (payload, next) = parsePayload(in: text, start: headerEnd.upperBound, lengthText: fields[2], end: end, byteCount: byteCount) else { return nil }
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (.init(id: id, text: payload), next)
    }

    private static func parsePayload(in text: String, start: String.Index, lengthText: String, end: String, byteCount: Int) -> (String, String.Index)? {
        guard lengthText.count <= 10, let length = Int(lengthText), length > 0, length <= byteCount, String(length) == lengthText,
              let payloadEnd = text.utf8.index(start, offsetBy: length, limitedBy: text.endIndex),
              let boundary = payloadEnd.samePosition(in: text.unicodeScalars),
              text.unicodeScalars[boundary...].starts(with: end.unicodeScalars) else { return nil }
        return (String(text.unicodeScalars[start..<boundary]), text.unicodeScalars.index(boundary, offsetBy: end.unicodeScalars.count))
    }
}
