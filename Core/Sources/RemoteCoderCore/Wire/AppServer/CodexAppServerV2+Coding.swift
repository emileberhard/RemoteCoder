extension CodexAppServerV2 {
    struct DynamicCodingKey: CodingKey, Hashable, Sendable {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }

        init(_ value: String) {
            stringValue = value
            intValue = nil
        }
    }
}
