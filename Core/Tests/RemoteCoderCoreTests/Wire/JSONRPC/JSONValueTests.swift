import Testing
@testable import RemoteCoderCore

struct JSONValueTests {
    @Test func onlyAStringYieldsAStringValue() {
        #expect(JSONValue.string("7").stringValue == "7")
        #expect(JSONValue.number(7).stringValue == nil)
        #expect(JSONValue.bool(true).stringValue == nil)
        #expect(JSONValue.null.stringValue == nil)
    }

    @Test func aHugeNumberIsNotCoercedToAString() {
        #expect(JSONValue.number(1e300).stringValue == nil)
    }
}
