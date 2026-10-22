/// Prompt markers are ASCII protocol delimiters. Search their UTF-8 bytes
/// directly, avoiding Foundation's Unicode search and String bridging.
enum PromptMarkerSearch {
    static func range(of marker: String, in text: String, range: Range<String.Index>? = nil,
                      backwards: Bool = false) -> Range<String.Index>? {
        let needle = marker.utf8
        let length = needle.count
        guard let first = needle.first else { return nil }
        let bytes = text.utf8
        let bounds = range ?? text.startIndex..<text.endIndex
        var remaining = bytes[bounds]
        while let start = backwards ? remaining.lastIndex(of: first) : remaining.firstIndex(of: first) {
            if let end = bytes.index(start, offsetBy: length, limitedBy: bounds.upperBound),
               bytes[start..<end].elementsEqual(needle) {
                return start..<end
            }
            if backwards {
                remaining = bytes[remaining.startIndex..<start]
            } else {
                remaining = bytes[bytes.index(after: start)..<remaining.endIndex]
            }
        }
        return nil
    }
}
