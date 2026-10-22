import Foundation
import Testing
@testable import RemoteCoderCore

struct DeviceToolProtocolTests {
    @Test func decodesInvokeAndEncodesDeclarationsAndCancel() throws {
        let invoke = try decode(DeviceToolInvoke.self, #"{"operationId":"photo-1","tool":"take_photo","version":1,"arguments":{"camera":"both","lens":"ultra_wide"},"deadlineUnixMs":1791075600000}"#)
        #expect(invoke.operationId == "photo-1")
        #expect(invoke.tool == "take_photo")
        #expect(invoke.version == 1)
        #expect(invoke.arguments == .object(["camera": .string("both"), "lens": .string("ultra_wide")]))
        #expect(invoke.deadlineUnixMs == 1791075600000)
        #expect(try json(DeviceToolsDeclare(tools: [.init(name: "take_photo", version: 1)])) ==
                decode(JSONValue.self, #"{"tools":[{"name":"take_photo","version":1}]}"#))
        #expect(try json(DeviceToolsDeclare(tools: [])) == decode(JSONValue.self, #"{"tools":[]}"#))
        let cancel = try decode(DeviceToolCancel.self, #"{"operationId":"photo-1"}"#)
        #expect(cancel.operationId == "photo-1")
        #expect(try json(cancel) == decode(JSONValue.self, #"{"operationId":"photo-1"}"#))
    }

    @Test func resultUsesImageAndOriginalWireShapes() throws {
        let fixture = #"{"operationId":"photo-1","outcome":"succeeded","detail":"Front original was not saved.","content":[{"type":"image","mimeType":"image/jpeg","data":"YmFjaw=="},{"type":"image","mimeType":"image/jpeg","data":"ZnJvbnQ="}],"originals":[{"path":"/uploads/back-wide.jpg","sha256":"abc","bytes":4000000,"camera":"back","lens":"wide","width":4032,"height":3024}]}"#
        let result = try decode(DeviceToolResult.self, fixture)
        #expect(result.outcome == .succeeded)
        #expect(result.content == [.image(mimeType: "image/jpeg", data: "YmFjaw=="), .image(mimeType: "image/jpeg", data: "ZnJvbnQ=")])
        #expect(result.originals == [.init(path: "/uploads/back-wide.jpg", sha256: "abc", bytes: 4_000_000,
                                          camera: .back, lens: .wide, width: 4032, height: 3024)])
        #expect(try json(result) == decode(JSONValue.self, fixture))
        #expect(try decode(DeviceToolResultReceipt.self, #"{"accepted":false}"#).accepted == false)
    }

    @Test(arguments: [
        ("foreground_required", DeviceToolRefusalReason.foregroundRequired),
        ("permission_denied", .permissionDenied), ("camera_unavailable", .cameraUnavailable),
        ("lens_unavailable", .lensUnavailable), ("busy", .busy), ("invalid_arguments", .invalidArguments),
        ("deadline_passed", .deadlinePassed),
    ])
    func refusalsKeepTheirReasonBytes(wire: String, reason: DeviceToolRefusalReason) throws {
        let result = DeviceToolResult(operationId: "photo-1", outcome: .refused, reason: reason,
                                      detail: nil, content: nil, originals: nil)
        #expect(try json(result) == .object(["operationId": .string("photo-1"), "outcome": .string("refused"), "reason": .string(wire)]))
    }

    @Test(arguments: ["cancelled", "failed"])
    func terminalOutcomesDecodeWithoutInventingContent(outcome: String) throws {
        let result = try decode(DeviceToolResult.self, "{\"operationId\":\"photo-1\",\"outcome\":\"\(outcome)\"}")
        #expect(result.outcome.rawValue == outcome)
        #expect(result.content == nil)
        #expect(result.originals == nil)
        #expect(result.reason == nil)
    }

    @Test func defaultsAndBothKeepBackLensAndFrontWide() throws {
        let defaults = try decode(TakePhotoArguments.self, "{}")
        #expect(defaults.camera == .back)
        #expect(defaults.lens == .wide)
        let both = try decode(TakePhotoArguments.self, #"{"camera":"both","lens":"telephoto"}"#)
        #expect(both.captures.map(\.camera) == [.back, .front])
        #expect(both.captures.map(\.lens) == [.telephoto, .wide])
    }

    @Test(arguments: [#"{"camera":"side"}"#, #"{"lens":"macro"}"#, #"{"camera":null}"#,
                      #"{"camera":"front","lens":"telephoto"}"#, #"{"flash":true}"#, "[]"])
    func rejectsInvalidPhotoArguments(fixture: String) {
        #expect(throws: (any Error).self) { try decode(TakePhotoArguments.self, fixture) }
    }

    @Test func unknownContentIsRejected() {
        #expect(throws: DecodingError.self) { try decode(DeviceToolContent.self, #"{"type":"audio","data":"AA=="}"#) }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ fixture: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(fixture.utf8))
    }

    private func json<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}
