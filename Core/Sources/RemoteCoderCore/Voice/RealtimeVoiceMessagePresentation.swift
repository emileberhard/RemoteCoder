import Foundation

enum RealtimeVoiceMessagePresentation {
    case request(String)
    case transcriptTail(String)

    static func parse(_ text: String) -> Self? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("<realtime_delegation>"), text.hasSuffix("</realtime_delegation>") else { return nil }
        let fields = DelegationFields()
        let parser = XMLParser(data: Data(text.utf8))
        parser.delegate = fields
        guard parser.parse(), let input = fields.values["input"],
              !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        switch fields.values["source"] {
        case nil: return .request(input)
        case "transcript_tail_flush": return .transcriptTail(fields.values["transcript_delta"] ?? "")
        default: return nil
        }
    }
}

private final class DelegationFields: NSObject, XMLParserDelegate {
    private var elements: [String] = []
    private(set) var values: [String: String] = [:]

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        guard attributes.isEmpty else { parser.abortParsing(); return }
        if elements.isEmpty {
            guard elementName == "realtime_delegation" else { parser.abortParsing(); return }
        } else {
            guard elements.count == 1, ["input", "source", "transcript_delta"].contains(elementName),
                  values[elementName] == nil else { parser.abortParsing(); return }
            values[elementName] = ""
        }
        elements.append(elementName)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if elements.count == 2, let name = elements.last {
            values[name, default: ""] += string
        } else if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parser.abortParsing()
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        _ = elements.popLast()
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        parser.abortParsing()
    }
}
