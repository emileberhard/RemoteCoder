import Foundation
import Testing

@testable import RemoteCoderCore

struct CodexAppServerV2TurnsTests {
    private static let cyberPrograms: [([String]?, String?)] = [
        (["standard", "daybreakBlue"], "daybreakBlue"),
        (["daybreakBlue"], "daybreakBlue"),
        (["standard"], nil),
        (["daybreakRed"], nil),
        (["futureProgram", "daybreakBlue"], "daybreakBlue"),
        (["futureProgram"], nil),
        ([], nil),
        (nil, nil),
    ]

    @Test(arguments: CodexAppServerV2TurnsTests.cyberPrograms)
    func discoveredDaybreakAccessAutomaticallyReachesTheTurnRequest(programs: [String]?, expected: String?) throws {
        var wire = CodexModelFixtures.wireModel("gpt-future", name: "Future", efforts: ["medium"])
        if let programs { wire["availableAccessPrograms"] = ["cyber": programs] }
        let catalog = CodexModelCatalog(models: try CodexModelFixtures.models([wire]), fetchedAt: .now)
        let option = try #require(catalog.entry(for: "gpt-future")?.option)
        let params = CodexAppServerV2.TurnStartParams(
            threadId: "thread-1", input: [.text(text: "hello", textElements: [])], cwd: nil,
            approvalPolicy: DispatchPolicy.approvalPolicy, sandboxPolicy: DispatchPolicy.turnSandbox,
            model: option.id, cyberAccessProgram: option.automaticCyberAccessProgram,
            effort: .medium, serviceTier: nil, additionalContext: nil, clientUserMessageId: "message-1"
        )
        let object = try encodedObject(params)
        #expect(object["model"] as? String == "gpt-future")
        #expect(object["cyberAccessProgram"] as? String == expected)
        #expect(object.keys.contains("cyberAccessProgram") == (expected != nil))
    }

    @Test
    func failedTurnRetainsItsErrorMessage() throws {
        let data = Data(#"{"id":"turn-1","items":[],"status":"failed","error":{"message":"failed","codexErrorInfo":"internalServerError","additionalDetails":"trace"}}"#.utf8)
        let turn = try JSONDecoder().decode(CodexAppServerV2.Turn.self, from: data)
        #expect(turn.error?.message == "failed")
    }

    enum EncodedServiceTier: Sendable {
        case absent
        case null
        case value(String)
    }

    @Test(arguments: [
        (nil as CodexAppServerV2.ServiceTierOverride?, EncodedServiceTier.absent),
        (.clear, .null),
        (.set(.fast), .value("fast")),
    ])
    func turnStartEncodesTheServiceTierOverrideAlongsideInteractionContext(
        tier: CodexAppServerV2.ServiceTierOverride?,
        expected: EncodedServiceTier
    ) throws {
        let params = CodexAppServerV2.TurnStartParams(
            threadId: "thread-1",
            input: [.text(text: "hello", textElements: [])],
            cwd: nil,
            approvalPolicy: DispatchPolicy.approvalPolicy,
            sandboxPolicy: DispatchPolicy.turnSandbox,
            model: "gpt",
            cyberAccessProgram: nil,
            effort: nil,
            serviceTier: tier,
            additionalContext: CodexInteractionMode.voice.additionalContext,
            clientUserMessageId: "message-1"
        )

        let object = try encodedObject(params)
        switch expected {
        case .absent:
            #expect(!object.keys.contains("serviceTier"))
        case .null:
            #expect(object["serviceTier"] is NSNull)
        case .value(let value):
            #expect(object["serviceTier"] as? String == value)
        }
        let context = try #require(object["additionalContext"] as? [String: Any])
        let entry = try #require(context[CodexInteractionMode.additionalContextKey] as? [String: Any])
        #expect(entry["kind"] as? String == "application")
        #expect((entry["value"] as? String)?.contains("voice-only mode on iOS") == true)
        #expect(object["clientUserMessageId"] as? String == "message-1")
    }

    @Test
    func turnSteerEncodesInteractionContext() throws {
        let params = CodexAppServerV2.TurnSteerParams(
            threadId: "thread-1",
            input: [.text(text: "one more thing", textElements: [])],
            expectedTurnId: "turn-1",
            additionalContext: CodexInteractionMode.voice.additionalContext,
            clientUserMessageId: "message-2"
        )

        let object = try encodedObject(params)
        let context = try #require(object["additionalContext"] as? [String: Any])
        let entry = try #require(context[CodexInteractionMode.additionalContextKey] as? [String: Any])

        #expect(entry["kind"] as? String == "application")
        #expect((entry["value"] as? String)?.contains("concise, conversational, and direct") == true)
    }

    private func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
