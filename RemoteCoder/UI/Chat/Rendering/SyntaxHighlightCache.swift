import Foundation

/// Owned by the serial rendering worker, never shared with the main actor.
struct SyntaxHighlightCache {
    private struct Key: Hashable { let language: String?; let code: String }
    private var values: [Key: AttributedString] = [:]
    private var order: [Key] = []
    private var bytes = 0

    mutating func highlight(_ code: String, language: String?) -> AttributedString {
        let key = Key(language: language, code: code)
        if let value = values[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return value
        }
        let value = SyntaxHighlighting.highlight(code, language: language)
        let size = code.utf8.count
        guard size <= 1_048_576 else { return value }
        values[key] = value
        order.append(key)
        bytes += size
        while order.count > 64 || bytes > 1_048_576 {
            let removed = order.removeFirst()
            values.removeValue(forKey: removed)
            bytes -= removed.code.utf8.count
        }
        return value
    }
}
